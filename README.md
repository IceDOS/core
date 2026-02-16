# 🧊 IceDOS

**IceDOS** is a highly opinionated **NixOS** framework designed to deliver a high-performance gaming and general-purpose computing experience. It balances "sane defaults" with a flexible configuration system to meet diverse user needs.

## ✨ Features

- **🎮 Gaming Optimized:** Pre-configured kernels, drivers, and tools for a low-latency gaming experience.

- **🛠️ Modular Configuration:** Easily extend the system via `config.toml` or custom Nix modules.

- **⚡ IceDOS CLI:** A suite of tools designed to manage your system without the complexity of raw Nix commands.

- **📂 State Management:** Isolated build environment within the `.state` directory to keep your source tree clean.

- **❄️ Inputs Management:** Easily control the resulting Flake inputs from your `config.toml`, or your **IceDOS** modules.

## 🚀 Installation

To get started with the default [template](https://github.com/IceDOS/template), run the following commands:

```bash
git clone https://github.com/icedos/template icedos
cd icedos
nix --extra-experimental-features "flakes nix-command pipe-operators" run . --boot
```

## ⚙️ Configuration

**IceDOS provides two primary ways to customize your system:**

1. **Simple:** Edit `config.toml`. This file exposes high-level options provided by **IceDOS** modules. You can find all available options of each module in their respective example `config.toml`.

2. **Advanced:** Add standard Nix modules to the `extra-modules` directory for full control.

> **ℹ️ NOTE**
> The `.state` directory stores the generated flake.nix and your flake.lock. You generally should not need to edit these manually.

## 🛠️ Usage

> **⚠️ WARNING**
> Do not use `nixos-rebuild` directly. **IceDOS** uses a custom wrapper to manage its modular architecture and state.

**Use the IceDOS CLI to manage your installation:**

Command |	Description
--- | ---
`icedos` | View all available tools in the **IceDOS** suite.
`icedos rebuild` | Apply configuration changes to the system.
`icedos rebuild --update-repos` | Update only the core **IceDOS** framework repositories.
`icedos update` | Update all flake inputs (System update).

## 🤝 Contributing

**We welcome contributions! To ensure your PR is directed to the right place, please follow these guidelines:**

- **Core Functionality:** PRs improving the framework core, CLI, or base modules should be made directly to this repository.

- **Specific Apps/Configs:** PRs regarding specific software suites or specialized configurations should be submitted to their respective repositories within the **IceDOS** Project organization.

- **🙏 We need a logo, please! 🙏**
