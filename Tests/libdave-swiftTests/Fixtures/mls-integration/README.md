# MLS integration fixtures

Drop captured fixture JSON files here; `MLSIntegrationFixtureTests` picks up
every `.json` file in this directory automatically and the test stops skipping.

See [../../../../Docs/MLS_INTEGRATION_FIXTURES.md](../../../../Docs/MLS_INTEGRATION_FIXTURES.md)
for what to capture, the safety rules for what must never be committed, and
`EXAMPLE.json.txt` in this directory for the file format.

Never commit production guild or account IDs, live key packages, private keys,
credentials, or real media.
