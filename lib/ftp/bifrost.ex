defmodule FTP.Bifrost do
  @moduledoc """
  Bifrost callbacks
  """
  @behavior :gen_bifrost_server

  import Ftp.Path
  import Ftp.Permissions

  require Record
  require Logger

  Record.defrecord(:file_info_rec, Record.extract(:file_info, from: "include/bifrost.hrl"))

  defmodule State do
    defstruct root_dir: "",
              current_directory: "",
              authentication_function: nil,
              expected_username: nil,
              expected_password: nil,
              session: nil,
              user: nil,
              permissions: nil,
              abort_agent: nil
  end

  # State, PropList (options) -> State
  def init(options) do
    options =
      if options[:limit_viewable_dirs] do
        permissions = struct(Ftp.Permissions, options[:limit_viewable_dirs])
        Keyword.put(options, :permissions, permissions)
      else
        options
      end

    struct(State, options)
  end

  # State, Username, Password -> {true OR false, State}
  def login(%State{authentication_function: authentication_function} = state, username, password)
      when is_function(authentication_function, 2) do
    case authentication_function.(username, password) do
      {:ok, session, user} -> {true, %{state | session: session, user: user}}
      {:error, :invalid_password} -> {false, state}
    end
  end

  def login(
        %State{expected_username: expected_username, expected_password: expected_password} =
          state,
        username,
        password
      ) do
    case {username, password} do
      {expected_username, expected_password} -> {true, %{state | user: expected_username}}
      _ -> {false, state}
    end
  end

  # State -> Path
  def current_directory(%State{current_directory: current_directory}) do
    current_directory
  end

  # State, Path -> State Change
  def make_directory(
        %State{current_directory: current_directory, root_dir: root_dir, permissions: permissions} =
          state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    have_read_access = allowed_to_read(permissions, working_path)
    have_write_access = allowed_to_write(permissions, working_path)

    cond do
      path_exists == true ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        case File.mkdir(working_path) do
          :ok ->
            {:ok, state}

          {:error, error} ->
            {:error, state}
        end
    end
  end

  # State, Path -> State Change
  def change_directory(
        %State{current_directory: current_directory, root_dir: root_dir, permissions: permissions} =
          state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    Logger.debug("This is working path on server: #{working_path}")

    new_current_directory =
      case String.trim_leading(working_path, root_dir) do
        "" -> "/"
        new_current_directory -> new_current_directory
      end

    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read(permissions, working_path)

    cond do
      is_directory == false ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false ->
        {:error, state}

      true ->
        {:ok, %{state | current_directory: current_directory}}
    end
  end

  # State, Path -> [FileInfo] OR {error, State}
  def list_files(
        %State{
          permissions: %{enabled: enabled} = permissions,
          current_directory: current_directory,
          root_dir: root_dir
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    {:ok, files} = File.ls(working_path)

    files =
      case enabled do
        true -> remove_hidden_folders(permissions, working_path, files)
        false -> files
      end

    if files == [] do
      {:error, state}
    else
      for file <- files, info = encode_file_info(permissions, file), info != nil do
        info
      end
    end
  end

  # State, Path -> State Change
  def remove_directory(
        %State{
          permissions: %{enabled: enabled} = permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read(permissions, working_path)
    have_write_access = allowed_to_write(permissions, working_path)

    cond do
      is_directory == false ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        if File.rmdir(working_path) == :ok do
          {:ok, state}
        else
          {:error, state}
        end
    end
  end

  # State, Path -> State Change
  def remove_file(
        %State{
          permissions: %{enabled: enabled} = permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read(permissions, working_path)
    have_write_access = allowed_to_write(permissions, working_path)

    cond do
      is_directory == true ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        if File.rm(working_path) == :ok do
          {:ok, state}
        else
          {:error, state}
        end
    end
  end

  # State, File Name, (append OR write), Fun(Byte Count) -> State Change
  def put_file(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        filename,
        mode,
        recv_data
      ) do
    working_path = determine_path(root_dir, current_directory, filename)

    if allowed_to_stor(permissions, working_path) do
      Logger.debug("working_dir: #{working_path}")

      case File.exists?(working_path) do
        true -> File.rm(working_path)
        false -> :ok
      end

      case receive_file(working_path, mode, recv_data) do
        :ok ->
          {:ok, state}

        :error ->
          {:error, state}
      end
    else
      {:error, state}
    end
  end

  # State, Path -> {ok, Fun(Byte Count)} OR error
  def get_file(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)

    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read(permissions, working_path)

    cond do
      is_directory == true ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false ->
        {:error, state}

      true ->
        {:ok, file} = :file.open(path, [:read, :binary])
        state = set_abort(state, false)
        {:ok, &send_file(state, file, &1), state}
    end
  end

  # State, Path -> {ok, FileInfo} OR {error, ErrorCause}
  def file_info(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)

    case encode_file_info(permissions, working_path) do
      nil -> {:error, :not_found}
      info -> {:ok, info}
    end
  end

  # State, From Path, To Path -> State Change
  def rename_file() do
    {:error, :not_supported}
  end

  # State, Command Name String, Command Args String -> State Change
  def site_command(_state, _command, _args) do
    {:error, :not_found}
  end

  # State -> {ok, [HelpInfo]} OR {error, State}
  def site_help(_) do
    {:error, :not_found}
  end

  # State -> State Change
  def disconnect(_state) do
    :ok
  end

  #
  # Helpers
  #

  def encode_file_info(permissions, file) do
    case File.stat(file) do
      {:ok, %{type: type, mtime: mtime, access: access, size: size}} ->
        type =
          case type do
            :directory -> :dir
            :regular -> :file
          end

        name = Path.basename(file)

        mode =
          cond do
            allowed_to_write(permissions, file) ->
              # :read_write
              0o600

            allowed_to_read(permissions, file) ->
              # :read
              0o400
          end

        file_info_rec(
          type: type,
          name: name,
          mode: mode,
          uid: 0,
          gid: 0,
          size: size,
          mtime: mtime
        )

      {:error, _reason} ->
        nil
    end
  end

  def receive_file(to_path, mode, recv_data) do
    case recv_data.() do
      {:ok, bytes, read_count} ->
        case File.write(to_path, bytes, [mode]) do
          :ok ->
            # Always append after 1st write
            receive_file(to_path, :append, recv_data)

          {:error, reason} ->
            :error
        end

      :done ->
        :ok
    end
  end

  def send_file(state, file, size) do
    unless aborted?(state) do
      case :file.read(file, size) do
        :eof -> {:done, state}
        {:ok, bytes} -> {:ok, bytes, &send_file(state, file, &1)}
        {:error, _} -> {:done, state}
      end
    else
      {:done, state}
    end
  end

  def set_abort(%State{abort_agent: nil} = state, false) do
    abort_agent = Agent.start_link(fn -> false end)
    %{state| abort_agent: abort_agent}
  end

  def set_abort(%State{abort_agent: abort_agent} = state, abort) when is_pid(abort_agent) and is_boolean(abort) do
    Agent.update(abort_agent, fn _abort -> abort end)
    state
  end

  def aborted?(%State{abort_agent: abort_agent}) when is_pid(abort_agent) do
    Agent.get(abort_agent, fn abort -> abort end)
  end
end
