# Release keys

`release.pub.pem` is the public half of the key that signs `SHA256SUMS` for
uml4termux releases. It is committed on purpose: a public key is not a secret, and
`fetch` needs it without reading anything from the network.

**Why this exists.** The digest pins in `lib/common.sh` answer *which bytes*, but
they live in the same tree as the code: whoever can write here can rewrite both a
pin and the file it names. A signature over `SHA256SUMS` — checked against a key
that is not inside the sums file — makes the sums *attributable*. `fetch` verifies
it before it uses a single digest from it, and a bad signature is fatal rather
than a reason to fall back.

**What it does not do** (do not read more into it than this):

* it does not survive a compromised release key;
* it does not make the mirror trustworthy — only `SHA256SUMS` becomes attributable;
* it does not replace the pins; both are checked.

## Using it

```sh
# default: packaging/keys/release.pub.pem from this tree
uml4termux fetch

# a fork with its own key
UML4TERMUX_RELEASE_PUBKEY=/path/to/your.pub.pem uml4termux fetch

# refuse to install anything from an unsigned sums file
UML4TERMUX_REQUIRE_SIGNATURE=1 uml4termux fetch
```

Without a signature at `<sums-url>.sig`, `fetch` warns and falls back to the pinned
digests; with `UML4TERMUX_REQUIRE_SIGNATURE=1` it refuses instead. With a signature
that does not verify it always refuses.

## Signing a release

The private key never lives in this repository:

```sh
UML4TERMUX_RELEASE_KEY=~/.config/uml4termux/release-key.pem ci/make-dist.sh
# -> dist/SHA256SUMS + dist/SHA256SUMS.sig, verified with the public key above
```

`make-dist` signs only when `UML4TERMUX_RELEASE_KEY` is readable, and says
`UNSIGNED` otherwise — an artefact that quietly claims to be signed would be worse
than one that admits it is not.

## Key identity

```sh
openssl pkey -pubin -in packaging/keys/release.pub.pem -outform DER | sha256sum | cut -c1-16
```

Error messages print this fingerprint, so a mismatch names the key that rejected
the file instead of just saying "verification failed".
