# Optional Windows release signing

Builds remain unsigned unless signing is explicitly enabled. Checksums detect
corruption; they do not establish a trusted publisher.

For a local signed build, install a trusted code-signing certificate and its
private key in Cert:\CurrentUser\My, install Windows SDK SignTool, then run:

    ./build-installer.ps1 -CertificateThumbprint <40-hex-thumbprint>

Use -SignToolPath or -TimestampUrl to select a different SDK or HTTPS RFC 3161
timestamp service. The certificate must support code signing and be current.
Inno invokes the signer for Setup, its temporary loaders, and the embedded
uninstaller. Each file must pass Authenticode trust, timestamp, and exact
certificate checks. A signing failure stops the build; it never falls back to
an unsigned release. Checksums are generated after signing.

For the GitHub tag-release workflow, configure:

* Repository variable REPLAY_SIGNING_ENABLED: true (unset keeps builds unsigned).
* Repository variable REPLAY_SIGNING_THUMBPRINT: the expected certificate.
* Repository secrets REPLAY_SIGNING_PFX_BASE64 and REPLAY_SIGNING_PFX_PASSWORD:
  a supported exportable publisher certificate, private key, and chain.

The workflow imports the PFX only on the ephemeral Windows release runner, deletes
the temporary PFX immediately, and removes the imported signing key in an always-run
cleanup step. No certificate or password belongs in source control. An HSM or
cloud signing provider needs its own authenticated SignTool integration; do not
export hardware-bound private keys to fit this workflow.

Verify a downloaded artifact against its adjacent checksum:

    ./verify-release.ps1 -Path ./obs-game-replay-automation-0.8.0-setup.exe

When signed releases are enabled, additionally require the independently obtained
publisher certificate thumbprint:

    ./verify-release.ps1 -Path ./obs-game-replay-automation-0.8.0-setup.exe -RequireSignature -ExpectedThumbprint <40-hex-thumbprint>

Default verification accepts unsigned builds explicitly. -RequireSignature
rejects unsigned, untrusted, untimestamped, or mismatched signatures. A certificate
does not guarantee immediate SmartScreen reputation.

References: [Inno SignTool](https://jrsoftware.org/ishelp/topic_setup_signtool.htm),
[signed uninstaller](https://jrsoftware.org/ishelp/topic_setup_signeduninstaller.htm),
[Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool).
