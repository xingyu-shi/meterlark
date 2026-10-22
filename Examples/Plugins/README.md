# Plugin examples

These optional packages demonstrate Meterlark's external plugin contract. They
are not bundled with the app. All endpoints use the reserved `example.test`
domain and require replacement with an API you control.

- [`Gateway/`](Gateway/) demonstrates cost metrics, quota progress, and a
  provider-specific JSON refresh exchange.
- [`ModelCatalog/`](ModelCatalog/) demonstrates a Bearer-authenticated model
  catalog with source-aware pricing.

See the [external plugin guide](../../docs/external-plugin.md) for response
formats, secret storage, validation, and installation. Do not place real
credentials in a manifest or example response.
