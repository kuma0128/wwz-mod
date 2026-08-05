# WWZ X90 Mod

Packaged World War Z X90 mod installers, version 4.1.

## Repository layout

- `WWZ_X90_Online_Mod_4.1_Slim_NoFirewall/` - expanded online installer files.
- `dist/v4.1/` - ready-to-download release archives and SHA-256 checksums.

## Release archives

| Archive | Contents |
| --- | --- |
| `WWZ_X90_Online_Mod_4.1_Slim_NoFirewall_FriendsOnly.zip` | Online bundle containing the standard and friends-only packages. |
| `WWZ_X90_FriendsOnly_Mod_4.1_Under10MB.zip` | Compact friends-only online package. |
| `WWZ_X90_Offline_Mod_4.1_Slim_NoFirewall.zip` | Offline slim package without firewall changes. |

Extract the selected archive, then run the included install command file. Use
`SHA256SUMS.txt` to verify a download before installation.

The offline artifact arrived with `Online` in its outer filename, but its
internal folder and installer are the offline edition. It is stored here under
the corrected `Offline` filename.
