defmodule EvaWeb.Providers do
  @moduledoc """
  The providers a session can be started against, and the models each one offers.

  `Eva.AI.Providers` decides what a provider *is* — base url, credentials, name. This module is the
  UI's view of that: a stable list to render in the new-session picker, keyed by the same
  `provider_name` Eva writes onto the session's index entry, plus the `/models` lookup that fills
  the model dropdown.

  Model lists are fetched per provider, not per session, so the picker works before a session (and
  therefore an `Eva.Coding.Session` pid) exists.
  """

  alias Eva.AI.Config.OpenAICompatible
  alias Eva.AI.OpenAICompatibleProvider
  alias Eva.AI.Providers

  @type t :: %{name: String.t(), label: String.t(), key: atom()}

  # `name` must match the `provider_name` `Eva.AI.Providers.build/1` puts on the config, since that
  # is what lands on the index entry and is looked up again when the session is opened.
  @catalog [
    %{name: "lmstudio", label: "LM Studio", key: :lmstudio},
    %{name: "opencode-go", label: "opencode go", key: :opencode_go}
  ]

  @doc "Every provider offered in the picker, in display order."
  @spec all() :: [t()]
  def all, do: @catalog

  @spec known?(String.t() | nil) :: boolean()
  def known?(name), do: Enum.any?(@catalog, &(&1.name == name))

  @doc "Human label for a `provider_name`, falling back to the name itself for retired providers."
  @spec label(String.t() | nil) :: String.t() | nil
  def label(nil), do: nil

  def label(name) do
    case Enum.find(@catalog, &(&1.name == name)) do
      nil -> name
      provider -> provider.label
    end
  end

  @doc "Provider new sessions start with unless the picker says otherwise."
  @spec default_name() :: String.t()
  def default_name do
    name = to_string(eva_config()[:provider])
    if known?(name), do: name, else: hd(@catalog).name
  end

  @doc "Model new sessions start with when the picker offers nothing better."
  @spec default_model() :: String.t() | nil
  def default_model, do: eva_config()[:model]

  @doc "Eva provider config for a `provider_name`, or nil if it isn't one we know."
  @spec config(String.t() | nil) :: OpenAICompatible.t() | nil
  def config(name) do
    case Enum.find(@catalog, &(&1.name == name)) do
      nil -> nil
      provider -> apply_overrides(Providers.build(provider.key))
    end
  end

  @doc """
  Model ids the provider advertises at `GET /models`.

  Errors come back as sentences rather than tuples because they are shown next to the picker — a
  provider being unreachable (LM Studio not running, no opencode key) is a normal thing to see
  here, not an exception.
  """
  @spec list_models(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_models(name) do
    case config(name) do
      nil -> {:error, "Unknown provider #{inspect(name)}."}
      config -> fetch_models(config)
    end
  end

  # -- Private --

  # EVA_BASE_URL moves the local LM Studio endpoint off its default port without needing a change
  # in eva. It is deliberately not applied to hosted providers, whose base url is not ours to move.
  defp apply_overrides(%OpenAICompatible{provider_name: "lmstudio"} = config) do
    case eva_config()[:base_url] do
      url when is_binary(url) -> %OpenAICompatible{config | base_url: url}
      _other -> config
    end
  end

  defp apply_overrides(config), do: config

  # Eva returns model ids in whatever order the provider listed them; sorted here because this is
  # the only place they are shown to a person.
  defp fetch_models(%OpenAICompatible{} = config) do
    case OpenAICompatibleProvider.list_models(config) do
      {:ok, models} -> {:ok, Enum.sort(models)}
      {:error, reason} -> {:error, describe(config, reason)}
    end
  end

  defp describe(config, {:http_error, status, _body}),
    do: "#{config.provider_name} answered with HTTP #{status}."

  defp describe(config, {:transport_error, reason}),
    do: "Could not reach #{config.provider_name}: #{transport(reason)}"

  defp describe(config, _reason),
    do: "#{config.provider_name} sent something that isn't a model list."

  defp transport(%{__exception__: true} = error), do: Exception.message(error)
  defp transport(reason), do: inspect(reason)

  defp eva_config, do: Application.get_env(:eva_web, :eva, [])
end
