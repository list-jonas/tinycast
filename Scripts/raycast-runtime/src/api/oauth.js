import { base64ToBytes, bytesToBase64, utf8Encode } from "../bytes.js";
import { hostCall, hostCallSync } from "../host.js";
import { nestedEnums } from "./enums.generated.js";

const base64UrlEncode = (bytes) => bytes.toBase64({ alphabet: "base64url", omitPadding: true });
const randomString = (length) => base64UrlEncode(base64ToBytes(hostCallSync("crypto", "random", [length])));

function computeCodeChallenge(verifier) {
  const hash = hostCallSync("crypto", "hash", ["sha256", bytesToBase64(utf8Encode(verifier)), null]);
  return base64UrlEncode(base64ToBytes(hash));
}

function redirectURIFor(method) {
  const { App, AppURI } = nestedEnums.OAuth.RedirectMethod;
  if (method === App) return "raycast://oauth?package_name=Extension";
  if (method === AppURI) return "com.raycast:/oauth?package_name=Extension";
  return "https://raycast.com/redirect?packageName=Extension";
}

// raycast.com/redirect sends the browser back to tinycast://oauth only when the state names the scheme.
function generateState(client) {
  const payload = {
    token: randomString(16),
    providerName: client?.providerName || "",
    providerId: client?.providerId || "",
    scheme: "tinycast",
  };
  return base64UrlEncode(utf8Encode(JSON.stringify(payload)));
}

export class TokenSet {
  constructor(options = {}) {
    this.accessToken = options.accessToken ?? options.access_token ?? "";
    this.refreshToken = options.refreshToken ?? options.refresh_token;
    this.idToken = options.idToken ?? options.id_token;
    this.tokenType = options.tokenType ?? options.token_type ?? "Bearer";
    this.scope = options.scope;
    this.expiresIn = options.expiresIn ?? options.expires_in;
    this.updatedAt = new Date(options.updatedAt ?? Date.now());
  }

  isExpired() {
    if (this.expiresIn == null) return false;
    const expiresAt = this.updatedAt.getTime() + (this.expiresIn - 30) * 1000;
    return Date.now() >= expiresAt;
  }
}

export class PKCEClient {
  constructor(options = {}) {
    this.redirectMethod = options.redirectMethod || nestedEnums.OAuth.RedirectMethod.Web;
    this.providerName = options.providerName || "";
    this.providerIcon = options.providerIcon;
    this.providerId = options.providerId || "";
    this.description = options.description || "";
  }

  async authorizationRequest(options) {
    if (!options || !options.endpoint || !options.clientId) {
      throw new Error("authorizationRequest requires endpoint and clientId");
    }

    const codeVerifier = randomString(32);
    const codeChallenge = computeCodeChallenge(codeVerifier);
    const codeChallengeMethod = "S256";
    const state = options.state || generateState(this);

    const redirectURI = options.extraParameters?.redirect_uri || redirectURIFor(this.redirectMethod);
    const url = new URL(options.endpoint);
    const query = [
      ["response_type", "code"],
      ["client_id", options.clientId],
      ...(options.scope ? [["scope", options.scope]] : []),
      ["redirect_uri", redirectURI],
      ["code_challenge", codeChallenge],
      ["code_challenge_method", codeChallengeMethod],
      ["state", state],
      ...Object.entries(options.extraParameters || {}),
    ];
    for (const [key, value] of query) if (value !== undefined && value !== null) url.searchParams.set(key, String(value));

    return {
      endpoint: options.endpoint,
      clientId: options.clientId,
      scope: options.scope,
      codeVerifier,
      codeChallenge,
      codeChallengeMethod,
      state,
      redirectURI,
      toURL() {
        return url.toString();
      },
    };
  }

  async authorize(request) {
    const url =
      typeof request === "string"
        ? request
        : request?.toURL
        ? request.toURL()
        : request?.url || request?.endpoint;
    if (!url) {
      throw new Error("authorize requires a valid authorization URL");
    }
    const state = typeof request === "object" ? request?.state : undefined;

    let res = await hostCall("oauth", "authorize", [url, state]);

    if (typeof res === "string") {
      try {
        res = JSON.parse(res);
      } catch {}
    }

    return {
      authorizationCode: res?.authorizationCode ?? res?.code ?? "",
      accessToken: res?.accessToken,
      state: res?.state,
    };
  }

  async getTokens() {
    let raw = await hostCall("oauth", "getTokens", [this.providerId]);
    if (!raw) return undefined;
    if (typeof raw === "string") {
      try {
        raw = JSON.parse(raw);
      } catch {
        return undefined;
      }
    }
    // A token stored without a time can't be dated, so it counts as expired and gets refreshed.
    return new TokenSet({ ...raw, updatedAt: raw.updatedAt ?? 0 });
  }

  async setTokens(tokens) {
    const set = typeof tokens === "string" ? JSON.parse(tokens) : tokens;
    const stamped = JSON.stringify({ ...set, updatedAt: new Date().toISOString() });
    await hostCall("oauth", "setTokens", [this.providerId, stamped]);
  }

  async removeTokens() {
    await hostCall("oauth", "removeTokens", [this.providerId]);
  }
}
