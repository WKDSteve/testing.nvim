  # testing ci land pushes a commit to a check branch ci/** first and moves main to it only when that run was green:
  # the push to main is then the same commit again. This job (seconds, no checkout) finds such a green run of this
  # workflow for this commit on a ci/** branch; then the legs are skipped and publish-ci-verified runs alone. Any other
  # answer (none, an API error) runs the legs as usual.
  already-verified:
    name: already verified on ci/**
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      actions: read
    outputs:
      verified: ${{ steps.look.outputs.verified }}
    steps:
      - id: look
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          SHA: ${{ github.sha }}
          WORKFLOW: ${{ github.workflow }}
        run: |
          n=$(gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=push&status=success&per_page=50" \
            --jq "[.workflow_runs[] | select(.name == env.WORKFLOW and (.head_branch | startswith(\"ci/\")))] | length" \
            || echo 0)
          if [ "${n:-0}" -gt 0 ]; then
            echo "green on a ci/** branch already: the legs are skipped"
            echo "verified=true" >> "$GITHUB_OUTPUT"
          else
            echo "verified=false" >> "$GITHUB_OUTPUT"
          fi

