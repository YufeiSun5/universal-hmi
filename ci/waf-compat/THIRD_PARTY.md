# Compatibility experiment dependency licenses

Scope: Linux/amd64 recursive imports of the candidate libraries, as resolved by
`go list -mod=readonly -deps -test -json .` with Go 1.27.3. The harness is
test-only; this is not an all-platform legal opinion or a product distribution.
No NOTICE-named files were found in these module trees. Test corpus licenses
are marked separately; module graph entries not linked by the harness are not
silently called runtime dependencies.

| Module | Version | License | Copied text |
|---|---|---|---|
| `github.com/corazawaf/coraza-coreruleset/coraza/v3` | v3.8.1 | Apache-2.0 | [text](LICENSES/github.com_corazawaf_coraza-coreruleset_coraza_v3@v3.8.1__LICENSE) |
| `github.com/corazawaf/coraza-coreruleset/crs/v4` | v4.30.0 | Apache-2.0 | [text](LICENSES/github.com_corazawaf_coraza-coreruleset_crs_v4@v4.30.0__LICENSE) |
| `github.com/corazawaf/coraza-coreruleset/crs/v4` | v4.30.0 | Apache-2.0 | [text](LICENSES/github.com_corazawaf_coraza-coreruleset_crs_v4@v4.30.0__rules_LICENSE) |
| `github.com/corazawaf/coraza/v3` | v3.8.1 | Apache-2.0 | [text](LICENSES/github.com_corazawaf_coraza_v3@v3.8.1__LICENSE) |
| `github.com/corazawaf/libinjection-go` | v0.3.3 | BSD-3-Clause | [text](LICENSES/github.com_corazawaf_libinjection-go@v0.3.3__LICENSE) |
| `github.com/goccy/go-json` | v0.10.5 | MIT | [text](LICENSES/github.com_goccy_go-json@v0.10.5__LICENSE) |
| `github.com/goccy/go-yaml` | v1.19.2 | MIT | [text](LICENSES/github.com_goccy_go-yaml@v1.19.2__LICENSE) |
| `github.com/gotnospirit/makeplural` | v0.0.0-20180622080156-a5f48d94d976 | BSD-2-Clause | [text](LICENSES/github.com_gotnospirit_makeplural@v0.0.0-20180622080156-a5f48d94d976__LICENSE) |
| `github.com/gotnospirit/messageformat` | v0.0.0-20221001023931-dfe49f1eb092 | BSD-2-Clause | [text](LICENSES/github.com_gotnospirit_messageformat@v0.0.0-20221001023931-dfe49f1eb092__LICENSE) |
| `github.com/jcchavezs/mergefs` | v0.1.1 | Apache-2.0 | [text](LICENSES/github.com_jcchavezs_mergefs@v0.1.1__LICENSE) |
| `github.com/kaptinlin/go-i18n` | v0.1.4 | MIT | [text](LICENSES/github.com_kaptinlin_go-i18n@v0.1.4__LICENSE) |
| `github.com/kaptinlin/jsonschema` | v0.4.6 | MIT | [text](LICENSES/github.com_kaptinlin_jsonschema@v0.4.6__LICENSE) |
| `github.com/kaptinlin/jsonschema` | v0.4.6 | MIT (test corpus only) | [text](LICENSES/github.com_kaptinlin_jsonschema@v0.4.6__testdata_JSON-Schema-Test-Suite_LICENSE) |
| `github.com/petar-dambovaliev/aho-corasick` | v0.0.0-20250424160509-463d218d4745 | MIT | [text](LICENSES/github.com_petar-dambovaliev_aho-corasick@v0.0.0-20250424160509-463d218d4745__LICENSE) |
| `github.com/tidwall/gjson` | v1.18.0 | MIT | [text](LICENSES/github.com_tidwall_gjson@v1.18.0__LICENSE) |
| `github.com/tidwall/match` | v1.1.1 | MIT | [text](LICENSES/github.com_tidwall_match@v1.1.1__LICENSE) |
| `github.com/tidwall/pretty` | v1.2.1 | MIT | [text](LICENSES/github.com_tidwall_pretty@v1.2.1__LICENSE) |
| `github.com/valllabh/ocsf-schema-golang` | v1.0.3 | Apache-2.0 | [text](LICENSES/github.com_valllabh_ocsf-schema-golang@v1.0.3__LICENSE) |
| `golang.org/x/net` | v0.58.0 | BSD-3-Clause | [text](LICENSES/golang.org_x_net@v0.58.0__LICENSE) |
| `golang.org/x/sync` | v0.22.0 | BSD-3-Clause | [text](LICENSES/golang.org_x_sync@v0.22.0__LICENSE) |
| `golang.org/x/text` | v0.41.0 | BSD-3-Clause | [text](LICENSES/golang.org_x_text@v0.41.0__LICENSE) |
| `google.golang.org/protobuf` | v1.36.11 | BSD-3-Clause | [text](LICENSES/google.golang.org_protobuf@v1.36.11__LICENSE) |
| `rsc.io/binaryregexp` | v0.2.0 | BSD-3-Clause | [text](LICENSES/rsc.io_binaryregexp@v0.2.0__LICENSE) |

Go 1.27.3 standard library: [BSD-3-Clause](LICENSES/go1.27.3-LICENSE).

Original copyright statements remain in the copied texts. Module checksums
are pinned in `go.sum`; upstream source remains in the module cache, not vendored.
Product packaging must regenerate its own actual linked-dependency inventory
when integration and target platforms are chosen.
