defmodule EvaWeb.ProvidersTest do
  # Not async: the default_name/0 test swaps the app-wide provider config out and back.
  use ExUnit.Case, async: false

  alias Eva.AI.Config.OpenAICompatible
  alias EvaWeb.Providers

  describe "all/0" do
    test "every entry is named after the provider_name Eva stamps on the config" do
      for provider <- Providers.all() do
        assert %OpenAICompatible{provider_name: name} = Providers.config(provider.name)
        assert name == provider.name
      end
    end

    test "offers both LM Studio and opencode go" do
      names = Enum.map(Providers.all(), & &1.name)
      assert "lmstudio" in names
      assert "opencode-go" in names
    end
  end

  describe "config/1" do
    test "opencode go points at the hosted endpoint" do
      assert %OpenAICompatible{base_url: "https://opencode.ai/zen/go/v1"} =
               Providers.config("opencode-go")
    end

    test "EVA_BASE_URL only moves the local provider" do
      # config/test.exs points :base_url at a closed port.
      assert %OpenAICompatible{base_url: "http://127.0.0.1:1"} = Providers.config("lmstudio")

      assert %OpenAICompatible{base_url: "https://opencode.ai" <> _} =
               Providers.config("opencode-go")
    end

    test "is nil for a provider we don't offer" do
      refute Providers.config("gpt-at-home")
      refute Providers.config(nil)
    end
  end

  describe "label/1" do
    test "falls back to the raw name so a retired provider still renders" do
      assert Providers.label("gpt-at-home") == "gpt-at-home"
      assert Providers.label(nil) == nil
      assert Providers.label("opencode-go") == "opencode go"
    end
  end

  describe "default_name/0" do
    test "falls back to the first provider when the configured one is unknown" do
      original = Application.get_env(:eva_web, :eva)
      on_exit(fn -> Application.put_env(:eva_web, :eva, original) end)

      Application.put_env(:eva_web, :eva, Keyword.put(original, :provider, "gpt-at-home"))
      assert Providers.default_name() == hd(Providers.all()).name
    end
  end

  describe "list_models/1" do
    test "an unreachable provider is an error sentence, not a raise" do
      assert {:error, message} = Providers.list_models("lmstudio")
      assert message =~ "Could not reach lmstudio"
    end

    test "an unknown provider is rejected before any request" do
      assert {:error, message} = Providers.list_models("gpt-at-home")
      assert message =~ "Unknown provider"
    end
  end
end
