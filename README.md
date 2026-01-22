# DocRepublisher

Republish HexDocs for packages that were built with an older ExDoc version.

## Configuration

Edit [config/config.exs](config/config.exs) and add packages:

```elixir
config :doc_republisher,
  exit_on_failure: false,
  log_file: "doc_republisher.log",
  packages: [
    {:package_name, github: "owner/repo"},
    {:another_package, github: "owner/repo", versions: ">= 1.0.0"}
  ]
```

Global options:
- `:exit_on_failure` (optional) - Stop processing on first failure (default: `false`)
- `:log_file` (optional) - File path for detailed logs (default: `"doc_republisher.log"`)

Package options:
- `:github` (required) - GitHub organization/repository (e.g., `"owner/repo"`)
- `:versions` (optional) - Version requirement string (default: `"> 0.0.0"`)

### Patches

To apply patches for specific package versions, create patch files in:
```
patches/<package_name>/<version>/001-fix-something.patch
```

Patches are applied in alphabetical order with `patch -p1`.

## Authentication

You must set the `HEX_API_KEY` environment variable with a Hex API key that has
write permissions.

Generate an API key at: https://hex.pm/settings/keys

## Usage

Run the republisher with your API key:

```bash
HEX_API_KEY=your_key_here mix run -e "DocRepublisher.run()"
```
