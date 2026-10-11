defmodule ParakeetDiar.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :parakeet_diar,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url:
        "https://github.com/Quickom2023/parakeet-diar/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "parakeet_diar_nif",
      make_precompiler_nif_versions: [versions: ["2.17"]],
      make_force_build: System.get_env("PARAKEET_DIAR_BUILD") in ["1", "true"],
      cc_precompiler: [
        only_listed_targets: true,
        compilers: %{
          {:unix, :linux} => %{
            "x86_64-linux-gnu" => {"gcc", "g++"}
          }
        }
      ],
      package: [
        files: ["lib", "c_src", "Makefile", "mix.exs", "README.md", "checksum.exs"]
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false}
    ]
  end
end
