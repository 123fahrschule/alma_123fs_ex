# Development and releases

## Checks

Use the versions in `.tool-versions` (CI also tests Elixir 1.18/OTP 27). Run
`mix deps.get --check-locked`, then:

```sh
MIX_ENV=test mix compile --warnings-as-errors
mix test --warnings-as-errors --cover      # threshold 90 %
mix format --check-formatted
mix credo --strict
mix docs --warnings-as-errors
mix dialyzer
```

Unit tests use `Req.Test` stubs and never reach Alma. For each behaviour change, first add a
failing test against the public API. Expected signatures must come from an independent
reference (the PHP client's tests or a separate computation), never from the code under test;
`test/fixtures/README.md` records where each fixture comes from.

Behaviour that depends on Alma is checked in the sandbox: `ALMA_API_KEY=sk_test_… mix test
--only integration`. There is no contact with Alma, so open questions are settled by sandbox
experiments and recorded in the README ("Verified in the sandbox" / "Unverified
assumptions"). Keep both sections true: a claim in the README must match the code and an
observation.

Keep library code independent of RegistrationService and Charger: persistence, business
rules and job queues belong to the consuming application.

## Releasing a version

1. Decide the version (see "Versions and upgrading" in the README): patch for compatible
   fixes, minor for new features **and**, before 1.0, for breaking changes.
2. In `CHANGELOG.md`, move the "Unreleased" entries under a new heading
   `## X.Y.Z — YYYY-MM-DD`. Add an **Upgrading** note for anything consumers must change
   (renamed function, new required option, different return value).
3. Set `@version` in `mix.exs` to `X.Y.Z` (it also feeds the `User-Agent` and the docs).
4. Run all checks above and, if Alma-facing behaviour changed, the sandbox tests.
5. Commit, then create an annotated tag equal to the version and push both:

   ```sh
   git tag -a X.Y.Z -m "X.Y.Z"
   git push origin main X.Y.Z
   ```

   Never move or delete a published tag: consumers' `mix.lock` files point at its commit.
   A wrong release is fixed by a new patch version.
6. Update consumers (RegistrationService) in their own pull request: change `tag:` and run
   `mix deps.update alma_123fs_ex` (see the README).
