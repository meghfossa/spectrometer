# Conda Analysis

While originally created for Python programs, Conda can package and distribute software for any language. It provides a full list of all dependencies installed in the environment, without providing a dependency graph.

## Project Discovery

Find the first file named `environment.yml`

## Analysis: conda list

We run `conda list --json` in order to get a complete list of all installed conda packages in the conda environment.

## Analysis: environment.yml

If the `conda list --json` operation does not succeed, we fall back to parsing the `environment.yml`, and getting the list of dependencies from the `dependencies` section of this file.