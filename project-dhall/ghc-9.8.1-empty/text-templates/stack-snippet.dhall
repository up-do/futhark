\(_stackage-resolver : Optional Text) ->
  ''
  user-message: "WARNING: This stack project is generated."

  ghc-options:
    "$locals": -fhide-source-paths
    futhark: -j -fwrite-ide-info -hiedir=.hie
  ''
