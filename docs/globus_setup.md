# Globus auth setup

This template uses Globus OAuth via `django-globus-portal-framework` +
`social-auth-app-django`. Initial access is restricted to:

- Identity UUID `0ab2be39-35fe-432b-a620-2ed86db7999d`
- Members of Globus group `f0c3d900-18af-11f1-8e43-0affecd7d007`

These defaults live in `.env.example` (`GLOBUS_ALLOWED_IDENTITIES`,
`GLOBUS_ALLOWED_GROUP`). Override per-environment by editing `.env` or the EB
environment variables.

## Register the Globus application

1. Sign in at https://app.globus.org/settings/developers
2. Click **Register a new app for science gateway or portal**.
3. Name it (e.g. `my-django-portal`).
4. **Scopes**: `openid`, `profile`, `email`,
   `urn:globus:auth:scope:groups.api.globus.org:view_my_groups_and_memberships`.
5. **Redirect URIs**: add one per environment.
   - Local: `http://localhost:8000/complete/globus/`
   - Docker: `http://localhost:8000/complete/globus/` (same as local)
   - Test and prod: the URI `scripts/one_time_setup.sh <env>` prints at the end, e.g.
     `https://dXXXX.cloudfront.net/complete/globus/` (or `https://<custom-domain>/complete/globus/`).
     Globus needs HTTPS here; the bare EB address has no certificate.
6. Copy the **Client UUID** and **Client Secret** into `.env`:
   ```
   GLOBUS_CLIENT_ID=<uuid>
   GLOBUS_CLIENT_SECRET=<secret>
   ```

## Allowlist enforcement

`accounts/permissions.enforce_globus_allowlist` runs in the social-auth pipeline
after `auth_allowed`. It checks:

1. If the user's identity UUID is in `GLOBUS_ALLOWED_IDENTITIES` → allow.
2. Else if their `identity_set` includes any identity that is also in the
   `GLOBUS_ALLOWED_GROUP` → allow.
3. Else → `AuthForbidden`, login rejected.

Every accept/reject is logged to the `audit` logger. Watch `docker compose logs web`
or EB logs for `globus_login_allowed` / `globus_login_denied` lines.

## Adding a collaborator

Two options:

- **Group invite (recommended)**: invite their Globus identity to the group
  `f0c3d900-18af-11f1-8e43-0affecd7d007`. No code change needed.
- **Identity allowlist**: add their identity UUID to `GLOBUS_ALLOWED_IDENTITIES` in `.env`,
  then rerun `scripts/one_time_setup.sh <env>` and accept only the final "push environment
  variables" step. (Avoid `aws ... --option-settings Namespace=...,Value=a,b` shorthand: the
  commas in a UUID list split the value.)

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `redirect URI mismatch` | EB CNAME or scheme drift | Add the exact URL to the Globus app; check `SOCIAL_AUTH_REDIRECT_IS_HTTPS` |
| `AuthForbidden` for a user who should be allowed | Identity not in allowlist and not in group | Update allowlist; logs show `globus_login_denied` with identity UUID |
| `AuthStateMissing` after callback | Session lost between login and callback (cookie/scheme mismatch) | Ensure login and callback use the same host+scheme; clear cookies |
