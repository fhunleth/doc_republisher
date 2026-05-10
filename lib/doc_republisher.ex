defmodule DocRepublisher do
  @moduledoc """
  Documentation for `DocRepublisher`.
  """

  require Logger

  @doc """
  Run the doc republisher for all configured packages.
  """
  @spec run() :: :ok
  def run do
    packages = Application.get_env(:doc_republisher, :packages, [])
    exit_on_failure = Application.get_env(:doc_republisher, :exit_on_failure, false)
    log_file = Application.get_env(:doc_republisher, :log_file, "doc_republisher.log")

    # Initialize log file
    File.write!(log_file, "Doc Republisher Log - #{DateTime.utc_now()}\n\n")

    # Store log file in process dictionary for access in helper functions
    Process.put(:log_file, log_file)

    log_both("Starting doc republisher...")

    case check_hex_auth() do
      :ok ->
        :ok

      {:error, reason} ->
        log_both("\nWARNING: #{reason}")
        log_both("Set the HEX_API_KEY environment variable to publish docs.")
        log_both("Generate an API key at: https://hex.pm/settings/keys\n")
        System.halt(1)
    end

    case fetch_latest_ex_doc_version() do
      {:ok, latest_ex_doc_version} ->
        log_both("Latest ex_doc version: #{latest_ex_doc_version}")
        {updated, failed} = process_packages(packages, latest_ex_doc_version, exit_on_failure)
        print_summary(updated, failed)

      {:error, reason} ->
        log_both("Failed to fetch latest ex_doc version: #{reason}")
        System.halt(1)
    end

    :ok
  end

  defp process_packages(packages, latest_ex_doc_version, exit_on_failure) do
    reducer = if exit_on_failure, do: :reduce_while, else: :reduce

    apply(Enum, reducer, [
      packages,
      {[], []},
      fn {package, opts}, {updated, failed} ->
        log_both("\nProcessing #{package}...")
        log_file_only("  Options: #{inspect(opts)}")

        github = Keyword.fetch!(opts, :github)
        git_url = "https://github.com/#{github}.git"
        version_req = Keyword.get(opts, :versions, "> 0.0.0")

        case fetch_recent_versions(package, version_req) do
          {:ok, versions} ->
            log_both("  Found versions: #{Enum.join(versions, ", ")}")

            result =
              apply(Enum, reducer, [
                versions,
                {updated, failed},
                fn version, {updated_acc, failed_acc} ->
                  log_both("  Checking #{package} #{version}...")

                  case doc_needs_update?(package, version, latest_ex_doc_version) do
                    {:ok, true} ->
                      log_both("    Republishing docs...")

                      case republish_docs(package, version, git_url, latest_ex_doc_version) do
                        :ok ->
                          log_both("    ✓ Successfully republished")

                          maybe_cont(
                            {[{package, version} | updated_acc], failed_acc},
                            exit_on_failure
                          )

                        {:error, reason} ->
                          log_both("    ✗ Failed: #{String.slice(reason, 0, 100)}...")
                          log_file_only("    Full error: #{reason}")
                          new_state = {updated_acc, [{package, version, reason} | failed_acc]}

                          if exit_on_failure do
                            {:halt, new_state}
                          else
                            maybe_cont(new_state, exit_on_failure)
                          end
                      end

                    {:ok, false} ->
                      maybe_cont({updated_acc, failed_acc}, exit_on_failure)

                    {:error, reason} ->
                      new_state = {updated_acc, [{package, version, reason} | failed_acc]}

                      if exit_on_failure do
                        {:halt, new_state}
                      else
                        maybe_cont(new_state, exit_on_failure)
                      end
                  end
                end
              ])

            maybe_cont(result, exit_on_failure)

          {:error, reason} ->
            new_state = {updated, [{package, "unknown", reason} | failed]}

            if exit_on_failure do
              {:halt, new_state}
            else
              maybe_cont(new_state, exit_on_failure)
            end
        end
      end
    ])
  end

  defp maybe_cont(state, true), do: {:cont, state}
  defp maybe_cont(state, false), do: state

  defp fetch_recent_versions(package, version_req) do
    log_file_only("  Fetching versions from hex.pm...")

    with {:ok, payload} <- hex_get("https://hex.pm/api/packages/#{package}"),
         releases when is_list(releases) <- Map.get(payload, "releases") do
      releases
      |> Enum.filter(fn release -> is_nil(release["retired"]) end)
      |> Enum.map(& &1["version"])
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&Version.match?(&1, version_req, allow_pre: false))
      |> Enum.sort(&(Version.compare(&1, &2) == :gt))
      |> Enum.take(3)
      |> then(&{:ok, &1})
    else
      nil -> {:error, "missing releases in Hex response"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp doc_needs_update?(package, version, latest_ex_doc_version) do
    url = "https://hexdocs.pm/#{package}/#{version}/"
    log_file_only("    Fetching docs from hexdocs.pm...")

    with {:ok, body} <- req_get(url) do
      case Regex.run(~r/<meta\s+name="generator"\s+content="ExDoc v([^"]+)">/i, body) do
        [_, ex_doc_version] ->
          case Version.parse(ex_doc_version) do
            {:ok, parsed_version} ->
              if Version.compare(parsed_version, latest_ex_doc_version) == :lt do
                log_file_only(
                  "    Docs need update (ExDoc #{parsed_version} < #{latest_ex_doc_version})"
                )

                {:ok, true}
              else
                log_file_only("    Docs are up-to-date (ExDoc #{parsed_version})")
                {:ok, false}
              end

            :error ->
              {:error, "invalid ExDoc version: #{ex_doc_version}"}
          end

        _ ->
          Logger.warning("Missing ExDoc generator tag for #{package} #{version}")
          {:ok, true}
      end
    end
  end

  defp verify_docs_updated(package, version, latest_ex_doc_version) do
    log_file_only("      Verifying docs were updated...")
    # Wait a moment for hexdocs to process.
    # 2 seconds is sometimes too short
    Process.sleep(5000)

    url = "https://hexdocs.pm/#{package}/#{version}/"

    with {:ok, body} <- req_get(url) do
      case Regex.run(~r/<meta\s+name="generator"\s+content="ExDoc v([^"]+)">/i, body) do
        [_, ex_doc_version] ->
          case Version.parse(ex_doc_version) do
            {:ok, parsed_version} ->
              if Version.compare(parsed_version, latest_ex_doc_version) == :eq do
                log_file_only("      ✓ Docs verified (ExDoc #{parsed_version})")
                :ok
              else
                {:error,
                 "Docs still show ExDoc #{parsed_version} instead of #{latest_ex_doc_version}"}
              end

            :error ->
              {:error, "invalid ExDoc version after publish: #{ex_doc_version}"}
          end

        _ ->
          {:error, "Missing ExDoc generator tag after publish"}
      end
    end
  end

  defp republish_docs(package, version, git_url, latest_ex_doc_version) do
    with_temp_dir(package, version, fn dir ->
      # Prepare environment with hex auth if available
      env = build_hex_env()

      with :ok <-
             (
               log_file_only("      Cloning repository...")
               run_cmd("git", ["clone", git_url, dir], timeout: 300)
             ),
           :ok <-
             (
               log_file_only("      Checking out v#{version}...")
               run_cmd("git", ["checkout", "v#{version}"], cd: dir, timeout: 60)
             ),
           :ok <- apply_patches(package, version, dir),
           :ok <-
             (
               log_file_only("      Getting dependencies...")
               run_cmd("mix", ["deps.get"], cd: dir, env: env, timeout: 300)
             ),
           :ok <-
             (
               log_file_only("      Updating ex_doc...")
               run_cmd("mix", ["deps.update", "ex_doc"], cd: dir, env: env, timeout: 300)
             ),
           :ok <-
             (
               log_file_only("      Publishing docs...")
               run_cmd("mix", ["hex.publish", "docs", "--yes"], cd: dir, env: env, timeout: 600)
             ),
           :ok <- verify_docs_updated(package, version, latest_ex_doc_version) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp with_temp_dir(package, version, fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "doc_republisher_#{package}_#{version}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp run_cmd(command, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout)
    cmd_opts = Keyword.merge([stderr_to_stdout: true], opts)

    {actual_command, actual_args} = wrap_with_timeout(command, args, timeout)
    {output, status} = System.cmd(actual_command, actual_args, cmd_opts)
    log_file_only("#{command} #{inspect(args)} -> #{output}")

    cond do
      status == 0 ->
        :ok

      timeout && status == 124 ->
        {:error, "Timed out after #{timeout}s: #{command} #{Enum.join(args, " ")}"}

      true ->
        {:error, String.trim(output)}
    end
  end

  # Wraps a command with `timeout` (or `gtimeout` on macOS) so a hung subprocess
  # — stuck git fetch, blocked Hex upload, etc. — fails cleanly instead of
  # blocking the whole run. SIGTERM at the deadline; SIGKILL 10 s after that.
  defp wrap_with_timeout(command, args, nil), do: {command, args}

  defp wrap_with_timeout(command, args, seconds) do
    case timeout_executable() do
      nil ->
        Logger.warning("`timeout` not on PATH; running #{command} without a timeout")
        {command, args}

      tool ->
        {tool, ["--kill-after=10", "#{seconds}", command | args]}
    end
  end

  defp timeout_executable do
    System.find_executable("timeout") || System.find_executable("gtimeout")
  end

  defp build_hex_env do
    base_env = System.get_env()

    # Pass through HEX_API_KEY if set
    if hex_key = System.get_env("HEX_API_KEY") do
      Map.put(base_env, "HEX_API_KEY", hex_key)
    else
      base_env
    end
  end

  defp apply_patches(package, version, dir) do
    patch_dir = Path.join(["patches", to_string(package), version])

    if File.dir?(patch_dir) do
      log_file_only("      Applying patches...")

      case File.ls(patch_dir) do
        {:ok, files} ->
          files
          |> Enum.sort()
          |> Enum.reduce_while(:ok, fn file, :ok ->
            patch_file = Path.join(patch_dir, file) |> Path.expand()

            if File.regular?(patch_file) do
              log_file_only("        Applying #{file}...")

              case run_cmd("sh", ["-c", "patch -p1 < #{patch_file}"], cd: dir, timeout: 60) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, "Patch #{file} failed: #{reason}"}}
              end
            else
              {:cont, :ok}
            end
          end)

        {:error, reason} ->
          {:error, "Failed to read patch directory: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp check_hex_auth do
    # HEX_API_KEY must be set since local hex config is password-protected
    if System.get_env("HEX_API_KEY") do
      :ok
    else
      {:error, "HEX_API_KEY environment variable not set"}
    end
  end

  defp fetch_latest_ex_doc_version do
    with {:ok, payload} <- hex_get("https://hex.pm/api/packages/ex_doc"),
         releases when is_list(releases) <- Map.get(payload, "releases"),
         versions <-
           releases
           |> Enum.filter(fn release -> is_nil(release["retired"]) end)
           |> Enum.map(& &1["version"])
           |> Enum.filter(&is_binary/1),
         latest when is_binary(latest) <-
           versions
           |> Enum.sort(&(Version.compare(&1, &2) == :gt))
           |> List.first(),
         {:ok, parsed_version} <- Version.parse(latest) do
      {:ok, parsed_version}
    else
      nil -> {:error, "missing releases in Hex response"}
      [] -> {:error, "no released ex_doc versions"}
      :error -> {:error, "invalid ex_doc version"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hex_get(url) do
    request = Req.new() |> ReqHex.attach()

    try do
      response = Req.request!(request, method: :get, url: url)
      normalize_response(response)
    rescue
      error ->
        {:error, Exception.message(error)}
    end
  end

  defp req_get(url) do
    try do
      response = Req.get!(url: url)
      normalize_response(response)
    rescue
      error ->
        {:error, Exception.message(error)}
    end
  end

  defp normalize_response(%{status: 200, body: body}) do
    {:ok, body}
  end

  defp normalize_response(%{status: status, body: body}) do
    {:error, "HTTP #{status}: #{body}"}
  end

  defp print_summary(updated, failed) do
    updated_count = length(updated)
    failed_count = length(failed)

    log_both("\nDoc republisher summary")
    log_both("Updated: #{updated_count}")

    if updated_count > 0 do
      updated
      |> Enum.reverse()
      |> Enum.each(fn {package, version} ->
        log_both("  - #{package} #{version}")
      end)
    end

    log_both("Failed: #{failed_count}")

    if failed_count > 0 do
      failed
      |> Enum.reverse()
      |> Enum.each(fn {package, version, reason} ->
        log_both("  - #{package} #{version}: #{reason}")
      end)
    end
  end

  defp log_to_both(msg, log_file) do
    IO.puts(msg)
    File.write!(log_file, msg <> "\n", [:append])
  end

  defp log_both(msg) do
    log_file = Process.get(:log_file)
    if log_file, do: log_to_both(msg, log_file), else: IO.puts(msg)
  end

  defp log_file_only(msg) do
    log_file = Process.get(:log_file)
    if log_file, do: File.write!(log_file, msg <> "\n", [:append])
  end
end
