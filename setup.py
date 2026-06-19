"""Build Cython native extensions (no .py source for core logic in wheels)."""
from setuptools import setup

try:
    from Cython.Build import cythonize
except ImportError:
    cythonize = None

ext_modules = None
if cythonize is not None:
    ext_modules = cythonize(
        [
            "bittensor_burn_message/core.pyx",
            "bittensor_burn_message/subnet_metrics.pyx",
        ],
        compiler_directives={
            "language_level": "3",
            "boundscheck": False,
            "wraparound": False,
            "cdivision": True,
        },
        build_dir="build/cython",
        annotate=False,
    )

setup(ext_modules=ext_modules)
