# External plugin development guide

This document is the development guide and versioned contract for external
plugins. A plugin is a package that is installed independently from the app;
it is not SwiftUI code linked into Meterlark.

## Quick start for plugin authors

Use this workflow when contributing a plugin:

1. Choose a stable reverse-DNS plugin ID, for example
   `com.example.service-usage`. Do not change the ID after publishing: it is
   used for activation state, configuration, and saved Dashboard layout IDs.
   IDs are limited to ASCII letters, digits, `.`, `_`, and `-`; they must not
   be empty, contain path separators, or contain an empty dot component such
   as `com..example`, `.`, or `..`.
2. Create a package directory containing a regular `plugin.json`. Choose one
   or more declared capabilities: `dashboard` for metric/progress data,
   `model-catalog` for source-aware model records, or both. Use `http-json`
   when one HTTPS `GET` plus a host-owned adapter is enough; use `stdio-json`
   only when the provider needs custom code (the current `stdio-json` contract
   is dashboard-only).
3. For a `dashboard` capability, define stable block IDs and stable tile/row
   IDs. Each dashboard block becomes an independently showable and reorderable
   component in the host's global Dashboard layout. A catalog-only plugin does
   not define plugin dashboard blocks; the host renders its records through the
   built-in `modelCatalog` component and combines them with custom records in
   model search.
4. Keep credentials in declared `secret` configuration fields. Never hardcode
   tokens in `plugin.json`, commit them, or print them from a `stdio-json`
   process.
5. Install the package through **Settings → Plugins → Install / update
   plugin**, configure it, explicitly enable it, and use **Refresh plugins** to
   run a local smoke test.
6. Open **Customize Dashboard layout** and verify that every block can be
   hidden, shown, reordered, and rendered with the expected data. The host
   owns the UI; a plugin contributes data and a dashboard document.

Recommended contribution contents:

```text
my-plugin/
  plugin.json
  # stdio-json only:
  bin/my-plugin-dashboard
```

For a repository contribution, include a redacted response fixture or
transcript and tests for the mapping/response behavior. The current host does
not provide a standalone `plugin validate` command; installation, activation,
and dashboard refresh are the authoritative validation paths.

Meterlark supports two external plugin transports:

- `http-json`: a manifest-only integration. The host performs the HTTPS
  request, decodes JSON, applies the declared dashboard mapping or typed
  capability adapter, and renders the result. No plugin executable or parser
  code is loaded.
- `stdio-json`: a code-capable integration for providers that cannot be
  expressed by the bounded HTTP/JSON contract. The host starts the declared
  executable across a process boundary and validates its dashboard response.

Neither transport loads SwiftUI, HTML, JavaScript, or plugin view code. The
host renders validated dashboard data with its own components. The Dashboard
layout is host-owned and global: it can show, hide, and reorder built-in
components together with blocks from enabled plugins. A plugin is independent
of the app's business code, but targets these versioned manifest, transport,
configuration, and dashboard contracts.

## Package

Choose **Settings → Plugins → Install / update plugin** and select a package
directory. The package must contain a regular `plugin.json`. Only the
`stdio-json` transport requires an executable entrypoint; an `http-json`
package can contain only its manifest. Package contents must not contain
symbolic links. Installation validates a staged copy and does not run an
entrypoint. The host rejects a `plugin.json` larger than 512 KiB before JSON
decoding.

Minimal manifest:

```json
{
  "manifestVersion": 1,
  "id": "com.example.example-gateway",
  "displayName": "Example Gateway",
  "version": "1.0.0",
  "protocolVersion": 1,
  "transport": "stdio-json",
  "entrypoint": "bin/example-gateway-dashboard"
}
```

The plugin is disabled after installation. The user must explicitly enable
it, and only enabled valid plugins are activated. `http-json` plugins are
never launched as processes.

## Localization

All user-facing text in the manifest and dashboard protocol accepts either a
legacy string or a localized text object. The legacy form remains valid:

```json
"displayName": "Example"
```

Use the localized form when a plugin supports more than its fallback language:

```json
"displayName": {
  "fallback": "Example",
  "translations": {
    "zh-Hans": "示例"
  }
}
```

The same shape is supported by configuration `title`, `description`, field
`label` and `placeholder`, choice-option `label`, and dashboard text values:
`literal`, `prefix`, `suffix`, `missing`, lifecycle messages, metric text,
progress-list headers, row labels, values, and status messages. Translation
keys use BCP-47-style language tags. The Host resolves an exact language first,
then its base language, then `en`, and finally `fallback`. Current app choices
map to `en` and `zh-Hans`.

For an `http-json` plugin, localized text belongs in `plugin.json`; the Host
keeps the response mapping and the localized dashboard document in memory, so
switching the app language re-renders the cached result without calling the
endpoint again. A `stdio-json` plugin may use the same object in its JSON
response. Translations are declarative data, not executable plugin code.

## HTTP/JSON transport

An `http-json` manifest declares a typed configuration schema, a bounded HTTPS
`GET`, response success conditions, and, for dashboard-capable plugins, a
dashboard mapping. The request and mapping are interpreted by the host; they
are not executable plugin code. A static protocol-v1 plugin sends one data
request per refresh. A refresh-capable protocol-v2 plugin may send one token
request before that data request. All `path` values are RFC 6901 JSON Pointers
resolved against one decoded response; they do not trigger additional
requests.

The following is an `http`/`configuration` fragment, not a complete installable
manifest. A complete `http-json` manifest must also declare at least one
capability. A dashboard-capable manifest must include a valid `dashboard`
object; a catalog-only manifest may omit it.

```json
{
  "transport": "http-json",
  "configuration": {
    "version": 1,
    "fields": [
      {
        "id": "endpoint",
        "label": "Endpoint",
        "kind": "url",
        "required": true,
        "defaultValue": "https://api.example.test/current"
      },
      {
        "id": "token",
        "label": "Authorization",
        "kind": "secret",
        "required": true
      }
    ]
  },
  "http": {
    "method": "GET",
    "urlField": "endpoint",
    "headers": [
      { "name": "Authorization", "valueField": "token" },
      { "name": "Accept", "value": "application/json" }
    ],
    "conditions": [
      { "path": "/success", "operator": "equals", "value": true }
    ]
  }
}
```

### Model-catalog capability

`model-catalog` is a host-owned capability for full model-information
responses. It reuses the same bounded `http-json` request and authentication
transport, but it does not map the response into a `metricGrid` or
`progressList`. The host adapter validates the full response, preserves
provider route and record identity, stores a trusted snapshot, and exposes the
records through the built-in `modelCatalog` Dashboard component and the shared
model-search window.

A catalog-only manifest has the following shape in addition to the normal
manifest fields:

```json
{
  "transport": "http-json",
  "capabilities": ["model-catalog"],
  "configuration": {
    "version": 1,
    "fields": [
      {
        "id": "endpoint",
        "label": "Catalog endpoint",
        "kind": "url",
        "required": true
      },
      {
        "id": "apiKey",
        "label": "API key",
        "kind": "secret",
        "required": true
      }
    ]
  },
  "http": {
    "method": "GET",
    "urlField": "endpoint",
    "headers": [
      { "name": "Authorization", "valueField": "apiKey", "valuePrefix": "Bearer " },
      { "name": "Accept", "value": "application/json" }
    ]
  }
}
```

The optional [model-catalog example](../Examples/Plugins/ModelCatalog/) uses
`https://gateway.example.test/v1/models` as a placeholder endpoint. Set your own
compatible API endpoint and credential before enabling it. Catalog refreshes
reuse the host pricing interval and the manual **Update pricing** action.
Remote records are eligible for local pricing only when no custom record
matches; custom, remote catalog, and ccusage/default prices remain source-aware.

The current mapping vocabulary uses RFC 6901 JSON Pointer paths. For example,
`/data/today_cost` can become a typed metric value, while
`/data/today_cost` and `/data/daily_quota` can become a progress row's
`current` and `maximum`. The host calculates the progress fraction and emits
explicit no-data or unavailable semantics when a value is missing; a mapper
never turns missing data into zero.

### Token refresh (protocol v2)

Static-header `http-json` manifests use `protocolVersion: 1`. A manifest that
declares `http.auth` must use `protocolVersion: 2` and `http.auth.version: 1`.
The host rejects an unsupported protocol or auth version before activation; it
does not silently ignore an auth declaration. The current capability supports
one host-owned refresh exchange followed by the existing idempotent `GET`.
It does not run a permanent background refresh loop.

The refresh declaration uses exact configuration-field references and exact
RFC 6901 response paths. OAuth-style form encoding can be declared as follows:

```json
{
  "protocolVersion": 2,
  "configuration": {
    "version": 1,
    "fields": [
      { "id": "endpoint", "label": "Data endpoint", "kind": "url", "required": true },
      { "id": "refreshEndpoint", "label": "Token endpoint", "kind": "url", "required": true },
      { "id": "refreshToken", "label": "Refresh token", "kind": "secret", "required": true },
      { "id": "clientID", "label": "Client ID", "kind": "text", "required": true },
      { "id": "clientSecret", "label": "Client secret", "kind": "secret", "required": true },
      { "id": "scope", "label": "Scope", "kind": "text", "required": true }
    ]
  },
  "http": {
    "method": "GET",
    "urlField": "endpoint",
    "headers": [{ "name": "Accept", "value": "application/json" }],
    "auth": {
      "version": 1,
      "profileID": "default",
      "refreshURLField": "refreshEndpoint",
      "refreshTokenField": "refreshToken",
      "encoding": "form",
      "refreshTokenParameter": "refresh_token",
      "grantTypeParameter": "grant_type",
      "grantTypeValue": "refresh_token",
      "clientIDField": "clientID",
      "clientSecretField": "clientSecret",
      "scopeField": "scope",
      "accessTokenPath": "/access_token",
      "refreshTokenPath": "/refresh_token",
      "expiresInPath": "/expires_in",
      "accessTokenHeader": "Authorization",
      "headerMode": "bearer",
      "expirySkewSeconds": 300,
      "missingExpiryPolicy": "unauthorized-retry",
      "tokenExpiredStatusCodes": [401]
    }
  }
}
```

Client credentials in auth version 1 are sent in the bounded refresh request
body. HTTP Basic client authentication, PKCE, browser login, device code, and
multi-stage exchanges require a future typed capability.

Provider-specific flows use the same lifecycle with different bounded wire
fields. For example, the repository's Example Gateway manifest uses JSON input with
`"refreshTokenParameter": "refresh"`, `grantTypeParameter: null`, nested or
provider-specific response paths (`/access` and `/refresh`), no expiry field,
and `"headerMode": "raw"`; the resulting `Authorization` header is the
returned value without a `Bearer` prefix. This is a declaration choice, not
provider-specific host code.

When `expiresInPath` is present and valid, the host refreshes within the
declared expiry skew. If expiry metadata is absent, `unauthorized-retry`
retains the token until a declared token-expired response (normally 401),
while `fixed-ttl` requires a bounded provider-declared fallback TTL. An
eligible expired response causes at most one forced refresh and one retry of
the data `GET`; a second failure is reported as authentication or permission
failure and is not retried indefinitely.

Refresh tokens remain in the declared `secret` field and Keychain account. If
the response contains a replacement, the host writes it there before making
the new access token usable. A missing replacement retains the old value. A
failed Keychain write publishes neither the replacement nor the new access
token and requires reconfiguration. Resetting the plugin configuration deletes
the same declared secret field, including a rotated value. Access tokens and
token response bodies are memory-only and are not written to public
configuration, logs, diagnostics, or error descriptions.

The optional [gateway example](../Examples/Plugins/Gateway/plugin.json)
declares an endpoint, a raw `Authorization` header, response conditions, four
metric tiles, and daily/monthly quota rows. It contains no provider executable,
Swift type, or custom parser. Replace its reserved-domain endpoints with your
compatible API before installing and explicitly enabling it. Examples are
source templates and are not copied into the release app.

### HTTP/JSON authoring checklist

- `configuration.fields` contains every field referenced by `urlField` and
  `valueField`.
- The endpoint is HTTPS and the `urlField` resolves to a configured URL.
- Header names are unique; static secret headers use `valueField`, not a
  literal token. Auth-managed headers are declared under `http.auth`.
- Response conditions describe the provider's success contract, such as
  `/success == true` and `/code == 0`.
- Every JSON Pointer is tested against both a normal response and a missing or
  malformed field. Missing values must render as no-data/unavailable semantics,
  not as a fabricated zero.
- Every block, tile, and row ID is unique within its required scope and remains
  stable across plugin updates.
- A metric grid declares a default `columns` value from 1 through 4. The user
  can later override the number of columns in the host layout editor.
- A progress list defines its header and rows; its progress fraction is derived
  by the host from `current` and `maximum`.

Protocol v1 intentionally supports only HTTPS `GET`, literal headers or
configuration-field headers, bounded response conditions, JSON Pointer lookup,
and host-owned `metricGrid`/`progressList` components. Protocol v2 adds only the
bounded `http.auth` refresh exchange described above. Neither version
evaluates JavaScript, Python, JSONPath filters, loops, arbitrary expressions,
or request-body templates. Providers that need those capabilities use
`stdio-json` or require a future versioned transport addition.

## Declarative configuration

An external plugin may add a `configuration` object to its manifest. The host
supports these field kinds:

| Kind | Effective JSON value |
| --- | --- |
| `text` | string |
| `url` | string |
| `integer` | integer |
| `decimal` | finite number |
| `boolean` | boolean |
| `choice` | one of the declared option IDs |
| `secret` | string, stored in Keychain |

Example:

```json
"configuration": {
  "version": 1,
  "title": "Example Gateway",
  "fields": [
    {
      "id": "endpoint",
      "label": "Endpoint",
      "kind": "url",
      "required": true,
      "defaultValue": "https://api.example.test"
    },
    {
      "id": "token",
      "label": "Authorization",
      "kind": "secret",
      "required": true
    },
    {
      "id": "period",
      "label": "Period",
      "kind": "choice",
      "defaultValue": "daily",
      "options": [
        { "id": "daily", "label": "Daily" },
        { "id": "monthly", "label": "Monthly" }
      ]
    }
  ]
}
```

The host renders a separate configuration window for each plugin. Ordinary
values are stored in the plugin's own JSON file below
`~/Library/Application Support/Meterlark/PluginConfigurations`; secret
values are stored separately in Keychain. The plugin receives the merged
effective object only in memory during refresh. For `http-json`, the host uses
secret values to construct static headers or the bounded token-refresh request;
it does not pass them to plugin code. A missing required value keeps the
provider unavailable and prevents a request or executable launch.

## stdio request and response

For each refresh the host starts a fresh process, sets its working directory
to the installed package, writes one JSON request line to stdin, closes stdin,
and reads one JSON dashboard document from stdout. The request has this shape:

```json
{
  "protocolVersion": 1,
  "type": "dashboard",
  "pluginID": "com.example.example-gateway",
  "configuration": {
    "endpoint": "https://api.example.test",
    "token": "the-configured-secret"
  }
}
```

The host enforces bounded request/response sizes, a timeout, valid UTF-8,
zero exit status, matching plugin ID, and dashboard schema validation. A
minimal successful response is:

```json
{
  "protocolVersion": 1,
  "pluginID": "com.example.example-gateway",
  "lifecycle": { "kind": "ready" },
  "blocks": [
    {
      "type": "metricGrid",
      "id": "quota",
      "columns": 2,
      "tiles": [
        {
          "id": "remaining",
          "header": { "text": "Remaining" },
          "primary": {
            "kind": "decimal",
            "value": 93.19,
            "display": { "text": "93.19" }
          },
          "detail": { "text": "Today" }
        }
      ]
    }
  ]
}
```

The executable must write the dashboard JSON to stdout and must not write
diagnostics there. Use stderr for diagnostics, omit secrets from diagnostics,
and exit non-zero when the request cannot be fulfilled. The host starts a new
process for each refresh; it does not keep a plugin process alive between
refreshes.

The dashboard protocol currently supports host-owned `metricGrid` and
`progressList` blocks. A metric grid may contain one through 16 tiles and uses
one through four columns; the provider defines each tile's header, value, and
detail. A progress list may contain progress, unavailable-progress, value, and
status rows; the provider defines its header and row content. The host also
provides the built-in `modelCatalog` Dashboard component. The source-independent
notification feed is exposed through the host popover's top-level bell, not as
a plugin response block or Dashboard layout component. Across either
transport, the host currently limits a dashboard document to 16 blocks, a
metric grid to 16 tiles, and a progress list to 64 rows. Dashboard requests
are limited to 64 KiB and dashboard responses to 512 KiB. Catalog responses
use a separate 8 MiB transport limit and additional record-aware bounds.
Users can hide and reorder validated built-in components and enabled-plugin
blocks in the global Dashboard layout, choose metric-grid columns for each
grid, and choose either an automatically content-fitting Dashboard height or a
fixed host-controlled height from 400 to 2000 points. These are host layout
preferences: a plugin does not control the Dashboard window size. In the
layout editor, both the component draft and the height draft update the
separate preview immediately; closing discards them, while saving applies them
to the main Dashboard. An installed but disabled plugin, or a plugin with
incomplete/invalid configuration, is not an active Dashboard or model-catalog
provider.

## Trust boundary

`http-json` does not execute plugin code, but it still permits a manifest to
request its configured HTTPS endpoint. The host restricts the endpoint and
redirect origin, bounds response size, and never writes secret values to the
public configuration file or error descriptions.

`stdio-json` is a process boundary, not a complete macOS sandbox. The app is
not currently distributed with an App Sandbox profile, so enabling a local
executable is an explicit trust decision. Do not install packages from an
untrusted source, and do not print configuration values or tokens from a
plugin.
