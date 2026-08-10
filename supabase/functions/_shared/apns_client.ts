export type PushTokenRow = {
  id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

export type ApnsSendResult = {
  ok: boolean
  status: number
  endpoint: string
  tokenEnvironment: "sandbox" | "production"
  reason?: string
  invalidate?: boolean
}

export type PushAlertContent = {
  title: string
  subtitle?: string
  body: string
}

export class ApnsClient {
  private constructor(
    private readonly keyId: string,
    private readonly teamId: string,
    private readonly bundleId: string,
    private readonly defaultEnvironment: "sandbox" | "production",
    private readonly privateKey: CryptoKey,
    private jwt: { token: string; issuedAt: number } | null = null,
  ) {}

  static async fromEnvironment(): Promise<ApnsClient> {
    const keyId = requireEnv("APNS_KEY_ID")
    const teamId = requireEnv("APNS_TEAM_ID")
    const bundleId = requireEnv("APNS_BUNDLE_ID")
    const defaultEnvironment = normalizeApnsEnvironment(Deno.env.get("APNS_ENVIRONMENT"))
    const privateKeyPem = requireEnv("APNS_PRIVATE_KEY").replace(/\\n/g, "\n")
    const privateKey = await importPrivateKey(privateKeyPem)
    return new ApnsClient(keyId, teamId, bundleId, defaultEnvironment, privateKey)
  }

  async send(
    token: PushTokenRow,
    alert: PushAlertContent,
    customData: Record<string, string> = {},
  ): Promise<ApnsSendResult> {
    const authorization = await this.authorizationHeader()
    const environment = normalizeApnsEnvironment(token.environment ?? this.defaultEnvironment)
    const host = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com"
    const apsAlert = compactAlertPayload(alert)
    const response = await fetch(`${host}/3/device/${token.token}`, {
      method: "POST",
      headers: {
        authorization,
        "apns-topic": this.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: apsAlert,
          sound: "default",
        },
        ...customData,
      }),
    })

    // HTTP 200 means APNs accepted the request for this device token string.
    // It does NOT prove the current physical install displayed the notification
    // (a stale still-active token can accept while the device listens on a newer one).
    if (response.status === 200) {
      return {
        ok: true,
        status: response.status,
        endpoint: host,
        tokenEnvironment: environment,
      }
    }
    const payload = await response.json().catch(() => ({}))
    const reason = typeof payload?.reason === "string" ? payload.reason : `status_${response.status}`
    // Only invalidate on Apple token-invalid signals for THIS token row.
    // Do not invalidate because a different token/send failed.
    const invalidate = ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)
    return {
      ok: false,
      status: response.status,
      endpoint: host,
      tokenEnvironment: environment,
      reason,
      invalidate,
    }
  }

  private async authorizationHeader(): Promise<string> {
    const nowSeconds = Math.floor(Date.now() / 1000)
    if (this.jwt && nowSeconds - this.jwt.issuedAt < 50 * 60) {
      return `bearer ${this.jwt.token}`
    }

    const header = base64UrlJson({ alg: "ES256", kid: this.keyId })
    const payload = base64UrlJson({ iss: this.teamId, iat: nowSeconds })
    const signingInput = `${header}.${payload}`
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      this.privateKey,
      new TextEncoder().encode(signingInput),
    )
    const token = `${signingInput}.${base64UrlBytes(new Uint8Array(signature))}`
    this.jwt = { token, issuedAt: nowSeconds }
    return `bearer ${token}`
  }
}

function compactAlertPayload(alert: PushAlertContent): Record<string, string> {
  const payload: Record<string, string> = {
    title: alert.title,
    body: alert.body,
  }
  if (alert.subtitle?.trim()) {
    payload.subtitle = alert.subtitle.trim()
  }
  return payload
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "")
  const binary = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0))
  return crypto.subtle.importKey(
    "pkcs8",
    binary.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )
}

function base64UrlJson(value: unknown): string {
  return base64UrlBytes(new TextEncoder().encode(JSON.stringify(value)))
}

function base64UrlBytes(bytes: Uint8Array): string {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`Missing required env var: ${name}`)
  return value
}

function normalizeApnsEnvironment(raw: string | null | undefined): "sandbox" | "production" {
  return raw === "production" ? "production" : "sandbox"
}
