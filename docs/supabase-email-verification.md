# Supabase Email Verification

Required Supabase Auth setting for FanGeo account creation:

1. Go to `Authentication` -> `Sign In / Providers` -> `Email`.
2. Set `Confirm email` to `ON`.
3. Keep SMTP configured to the existing Resend sender, `support@fangeosports.com`.
4. Allowlist these redirect URLs:
   - `fangeo://email-confirmed`
   - `fangeo://auth-callback`

When email confirmation is enabled, new fan and business-owner signups must confirm their email before gaining full app access. Opening the confirmation deep link (`fangeo://email-confirmed` / `fangeo://auth-callback`) exchanges the Auth callback for a session when the provider returns one; FanGeo then completes the deferred fan profile and enters Discover with the Welcome Guide. If confirmation verifies the email without a persistent session, the app routes to Sign In with a success notice and finishes profile + Welcome Guide after the user signs in.
