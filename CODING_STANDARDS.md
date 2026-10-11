# Coding standards

Mechanical rules live in `ci/test.sh` and `ci/build.sh`, not here. These are the judgment calls a reviewer applies to a diff.

## Claims match evidence

Every behavior the README or a comment asserts (works on X, fixes Y, safe because Z) was observed in this change or an earlier one, or is marked untested. Flag a claim about an environment the change never ran in, such as "works on X11" when only Wayland was tested.

## Trust decisions stay explicit

A change to `update.sh`, `check-deb.sh`, or `ci/check-dist.sh` keeps each check failing closed and comes with a `ci/test.sh` case that fails without it.
