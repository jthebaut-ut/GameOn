import AuthenticationServices
import Combine
import CryptoKit
import Security
import SwiftUI
import UIKit

struct FanGeoAppleSignInButton: View {
    @ObservedObject var viewModel: MapViewModel
    let accountMode: AppleAuthAccountMode
    var entryPoint: AppleAuthEntryPoint = .signIn
    var isEnabled: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentNonce: String?
    @State private var isAuthorizing = false
    @StateObject private var signupAppleCoordinator = FanGeoSignupAppleAuthCoordinator()

    private var isSignupEntry: Bool {
        entryPoint == .fanSignup || entryPoint == .businessSignup
    }

    var body: some View {
        Group {
            if isSignupEntry {
                Button {
                    Task { await beginSignupWithAgeGate() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                            .font(.body.weight(.semibold))
                        Text(L10n.t("age_gate_continue_with_apple"))
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isAuthorizing || !isEnabled || viewModel.isSafeLoginInFlight || AgeAccessGateService.shared.isRequestInFlight)
                .opacity(isAuthorizing || !isEnabled || viewModel.isSafeLoginInFlight ? 0.72 : 1)
                .accessibilityLabel(L10n.t("age_gate_continue_with_apple"))
            } else {
                SignInWithAppleButton(.continue) { request in
                    configureAppleRequest(request)
                } onCompletion: { result in
                    handleAuthorizationResult(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .disabled(isAuthorizing || !isEnabled || viewModel.isSafeLoginInFlight)
                .opacity(isAuthorizing || !isEnabled || viewModel.isSafeLoginInFlight ? 0.72 : 1)
            }
        }
    }

    @MainActor
    private func beginSignupWithAgeGate() async {
        guard !isAuthorizing, isEnabled, !viewModel.isSafeLoginInFlight else { return }
        guard await viewModel.requireAgeAccessForSignUp() else { return }

        isAuthorizing = true
        print("[AppleAuthDebug] buttonTapped=true accountMode=\(accountMode.rawValue) entryPoint=\(entryPoint.rawValue)")
        if entryPoint == .fanSignup {
            print("[FanSignupDebug] appleButtonTapped=true")
        }
        viewModel.clearAppleAuthMessage(accountMode: accountMode, reason: "retry")

        let nonce = Self.randomNonceString()
        currentNonce = nonce
        signupAppleCoordinator.onCompletion = { [self] result in
            handleAuthorizationResult(result)
        }
        signupAppleCoordinator.start(nonceSHA256: Self.sha256(nonce))
    }

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        isAuthorizing = true
        print("[AppleAuthDebug] buttonTapped=true accountMode=\(accountMode.rawValue) entryPoint=\(entryPoint.rawValue)")
        print("[AppleAuthDebug] bypassEmailPasswordSignup=true")
        print("[AppleAuthDebug] authorizationStarted=true")
        Task {
            viewModel.clearAppleAuthMessage(accountMode: accountMode, reason: "retry")
        }
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    private func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) {
        defer { isAuthorizing = false }

        switch result {
        case .success(let authorization):
            print("[AppleAuthDebug] authorizationCompletion=success")
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                print("[AppleAuthDebug] credentialReceived=false credentialType=\(type(of: authorization.credential))")
                Task { await viewModel.handleAppleAuthFailure(message: "Apple sign in returned an unexpected credential type.", accountMode: accountMode) }
                return
            }
            print("[AppleAuthDebug] credentialReceived=true userIdentifierPresent=\(!credential.user.isEmpty)")
            print("[AppleAuthDebug] authorizationCodeExists=\(credential.authorizationCode != nil)")
            print("[AppleAuthDebug] identityTokenExists=\(credential.identityToken != nil)")
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let rawNonce = currentNonce else {
                print("[AppleAuthDebug] identityTokenReceived=false rawNonceExists=\(currentNonce != nil)")
                Task { await viewModel.handleAppleAuthFailure(message: "Apple sign in did not return a valid identity token.", accountMode: accountMode) }
                return
            }
            print("[AppleAuthDebug] identityTokenReceived=true identityTokenLength=\(identityToken.count)")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleCredentialReady=true emailProvidedByApple=\(credential.email != nil)")
            }
            Task {
                await viewModel.signInWithAppleIdentityToken(
                    identityToken,
                    rawNonce: rawNonce,
                    email: credential.email,
                    fullName: credential.fullName,
                    accountMode: accountMode,
                    entryPoint: entryPoint
                )
            }

        case .failure(let error):
            let nsError = error as NSError
            print("[AppleAuthDebug] authorizationCompletion=failure domain=\(nsError.domain) code=\(nsError.code) localized=\(error.localizedDescription) raw=\(String(reflecting: error))")
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                print("[AppleAuthDebug] authorizationCancelled=true")
                return
            }
            Task { await viewModel.handleAppleAuthFailure(message: error.localizedDescription, accountMode: accountMode) }
        }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class FanGeoSignupAppleAuthCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var onCompletion: ((Result<ASAuthorization, Error>) -> Void)?

    func start(nonceSHA256: String) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonceSHA256
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
        print("[AppleAuthDebug] authorizationStarted=true")
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // iOS 26 deprecates both `UIWindow()` and `UIWindow(frame:)`; the only supported
        // initializer is `UIWindow(windowScene:)`. Prefer an existing window and, failing
        // that, build one bound to an active scene.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let existing = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first {
            return existing
        }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            return UIWindow(windowScene: scene)
        }
        // Unreachable while presenting UI: an interactive authorization always runs with a
        // foreground window scene. Surface loudly rather than fabricating a detached window.
        fatalError("No active UIWindowScene available for Apple Sign In presentation anchor")
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onCompletion?(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onCompletion?(.failure(error))
    }
}
