      # @@NOTE|raw@@
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false
          repository: @@REPO|yaml@@
          path: @@PREFIX|raw@@@@NAME@@
          ref: @@REF@@
