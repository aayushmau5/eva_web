defmodule EvaWeb.FontsTest do
  use ExUnit.Case, async: true

  alias EvaWeb.Fonts

  describe "list/0" do
    test "returns families for the UI and a monospaced subset" do
      assert %{ui: ui, mono: mono} = Fonts.list()

      assert is_list(ui) and ui != []
      assert is_list(mono) and mono != []
      assert Enum.all?(ui ++ mono, &is_binary/1)
    end

    # Fontconfig lists the OS's internal faces — fallback stacks and UI variants — alongside the
    # real ones, and they are not things a user should be offered.
    test "leaves out the system's private faces" do
      %{ui: ui, mono: mono} = Fonts.list()

      refute Enum.any?(ui ++ mono, &String.starts_with?(&1, "."))
    end

    test "each list is sorted and free of duplicates" do
      %{ui: ui, mono: mono} = Fonts.list()

      for families <- [ui, mono] do
        assert families == Enum.uniq(families)
        assert families == Enum.sort_by(families, &String.downcase/1)
      end
    end

    test "is cached, so reopening the picker does not shell out again" do
      assert Fonts.list() == Fonts.list()
    end
  end

  describe "known?/1" do
    test "recognises a family the system reported" do
      %{ui: [family | _]} = Fonts.list()

      assert Fonts.known?(family)
    end

    test "recognises a monospaced family too" do
      %{mono: [family | _]} = Fonts.list()

      assert Fonts.known?(family)
    end

    # This is the check that stops an arbitrary string reaching a style attribute.
    test "rejects anything the system did not report" do
      refute Fonts.known?("No Such Font 91827")
      refute Fonts.known?(~s(Arial"; background: url\(evil\)))
      refute Fonts.known?(nil)
      refute Fonts.known?(:arial)
    end
  end
end
