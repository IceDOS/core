import sys

from .main import main

try:
    code = main()
except KeyboardInterrupt:
    # Only before `nh` starts (genflake/lock); runner.py owns interrupts after,
    # where activation — not lock state — is what the user needs to hear about.
    print("interrupted — partial lock updates are safe to retry", file=sys.stderr)
    raise SystemExit(130) from None

raise SystemExit(code)
