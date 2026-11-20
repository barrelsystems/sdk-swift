/// Ed25519 public verification key, embedded at build time -- public by
/// design, only its private half is secret. Matches `defaultBaseURL`
/// below specifically; a dev/test stage signs with a different keypair.
let publicEd25519KeyPEM = """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEAoQf7qhQlr7W9x6EvTwriO/EluLP1IWbn77nFRkxXKZ4=
  -----END PUBLIC KEY-----

  """

let defaultBaseURL = "https://ingest.barrel.codes"
