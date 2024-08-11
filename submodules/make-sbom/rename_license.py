def debian_license(license: str) -> str:
    if license == "Apache-1":
        license = "Apache-1.0"
    elif license == "Apache-2":
        license = "Apache-2.0"
    elif license == "BSD1":
        license = "BSD-1-Clause"
    elif license == "BSD2":
        license = "BSD-2-Clause"
    elif license == "BSD3":
        license = "BSD-3-Clause"
    elif license == "GFDL-1.1-invariants":
        license = "GFDL-1.1-no-invariants-only"
    elif license == "GFDL-1.1+-invariant":
        license = "GFDL-1.1-no-invariants-or-later"
    elif license == "GFDL-1.1-no-invariant":
        license = "GFDL-1.1-no-invariants-only"
    elif license == "GFDL-1.1+-no-invariant":
        license = "GFDL-1.1-no-invariants-or-later"
    elif license == "GFDL-1.1":
        license = "GFDL-1.1-only"
    elif license == "GFDL-1.1+":
        license = "GFDL-1.1-or-later"
    elif license == "GFDL-1.2-invariants":
        license = "GFDL-1.2-no-invariants-only"
    elif license == "GFDL-1.2+-invariant":
        license = "GFDL-1.2-no-invariants-or-later"
    elif license == "GFDL-1.2-no-invariant":
        license = "GFDL-1.2-no-invariants-only"
    elif license == "GFDL-1.2+-no-invariant":
        license = "GFDL-1.2-no-invariants-or-later"
    elif license == "GFDL-1.2":
        license = "GFDL-1.2-only"
    elif license == "GFDL-1.2+":
        license = "GFDL-1.2-or-later"
    elif license == "GFDL-1.3-invariants":
        license = "GFDL-1.3-no-invariants-only"
    elif license == "GFDL-1.3+-invariant":
        license = "GFDL-1.3-no-invariants-or-later"
    elif license == "GFDL-1.3-no-invariant":
        license = "GFDL-1.3-no-invariants-only"
    elif license == "GFDL-1.3+-no-invariant":
        license = "GFDL-1.3-no-invariants-or-later"
    elif license == "GFDL-1.3":
        license = "GFDL-1.3-only"
    elif license == "GFDL-1.3+":
        license = "GFDL-1.3-or-later"
    elif license == "GPL-2":
        license = "GPL-2.0-only"
    elif license == "GPL-2+":
        license = "GPL-2.0-or-later"
    elif license == "GPL-3":
        license = "GPL-3.0-only"
    elif license == "GPL-3+":
        license = "GPL-3.0-or-later"
    elif license == "LGPL-2":
        license = "LGPL-2.0-only"
    elif license == "LGPL-2+":
        license = "LGPL-2.0-or-later"
    elif license == "LGPL-2.1":
        license = "LGPL-2.1-only"
    elif license == "LGPL-2.1+":
        license = "LGPL-2.1-or-later"
    elif license == "LGPL-3":
        license = "LGPL-3.0-only"
    elif license == "LGPL-3+":
        license = "LGPL-3.0-or-later"
    return license
