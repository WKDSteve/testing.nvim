
@@WHY|raw@@
  publish-ci-verified:
    name: publish ci-verified branch
    needs: [pipeline]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: [self-hosted, windows]
    timeout-minutes: 15
    # `shell: bash` resolves to the WSL launcher on this machine; Git Bash is named explicitly, in 8.3 form because
    # the shell string is split at spaces.
    defaults:
      run:
        shell: C:\PROGRA~1\Git\bin\bash.exe --noprofile --norc -e -o pipefail {0}
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
      # Never move ci-verified backwards along main's history: two pushes can finish
      # out of order, and the older run must not overwrite the newer verified commit.
      # If main's history was rewritten (compare status 'diverged'), ci-verified is
      # deliberately reset to the new verified commit. The
      # lookup fails closed (an API or network error stops the job instead of
      # falling through to a push) and the update carries a lease on the tip it
      # compared against.
      - name: Publish ci-verified
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          SHA: ${{ github.sha }}
        run: |
          # Look the branch up on the remote instead of inferring "missing" from an API
          # error: a failed lookup must stop the job, not fall through to a push.
          # A concurrent run may move ci-verified between the comparison and the push
          # (lease rejected). Re-read the tip and compare again: if the newer run is
          # already ahead of this commit there is nothing left to publish, so that is
          # success, not a failure.
          for attempt in 1 2 3 4; do
            tip=$(git ls-remote --heads origin refs/heads/ci-verified | cut -f1)
            if [ -z "$tip" ]; then
              # First publish. A plain push creates the branch and is rejected if a
              # concurrent run created it first; the next attempt then compares.
              git push origin HEAD:refs/heads/ci-verified && exit 0
              echo "first publish failed on attempt $attempt (another run may have created the branch)"
              [ "$attempt" -lt 4 ] && sleep $((attempt * 2))
              continue
            fi
            status=$(gh api "repos/$REPO/compare/$tip...$SHA" --jq .status)
            case "$status" in
              behind | identical)
                echo "ci-verified ($tip) is '$status' relative to $SHA (published or superseded); leaving it alone"
                exit 0
                ;;
              ahead | diverged)
                # The lease makes the server refuse the update if ci-verified moved since
                # the comparison, so an older run can never overwrite a newer one.
                git push origin HEAD:refs/heads/ci-verified --force-with-lease="refs/heads/ci-verified:$tip" && exit 0
                echo "push failed on attempt $attempt (lease rejected or another error, see the git output above)"
                [ "$attempt" -lt 4 ] && sleep $((attempt * 2))
                ;;
              *)
                echo "::error::unexpected compare status '$status' for $tip...$SHA"
                exit 1
                ;;
            esac
          done
          echo "::error::could not publish ci-verified after 4 attempts"
          exit 1
