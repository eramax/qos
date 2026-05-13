# QOS Project Structure Refactor

## Goal

Refactor the project from a file-oriented build layout into a composition-based
build model with encapsulated feature stacks.

The new model must support:

- minimal common `base`
- additive profiles only
- explicit feature selection per profile
- self-contained feature stacks that may include packages, rootfs files,
  s6 services, kernel config, pipeline hooks, and tests
- a builder that resolves profiles and selected features into the final build

This is not only a directory cleanup. It is a real build model change.

## Core Model

The new composition rule is:

`final build = base profile + selected feature stacks`

Rules:

- `base` must stay minimal
- profiles are additive only
- profiles select features explicitly
- not every feature is present in every profile
- a feature may require packages, kernel config, and s6 services together
- those related artifacts should live in the same feature directory

## Target Structure

```text
/components
    /<feature-name>
        component.yaml
        /rootfs
        /s6
        /kernel
        /hooks
        /tests

/profiles
    base.yaml
    server.yaml
    desktop.yaml

/builder
    resolve.sh
    merge.sh
    pipeline.sh
    lib/

/build
    generated/
    staging/

/dist
    qos-server.iso
    qos-desktop.iso
```

## Component Model

Each component is a feature stack, not a package bucket.

Examples:

- `networking`
- `dropbear`
- `nftables`
- `cloud-init`
- `k3s`
- `desktop-ui`
- `seatd`
- `pipewire`
- `gpu-intel`
- `gpu-amd`

Each component may contribute:

- packages
- rootfs files
- s6 service definitions
- kernel config fragments
- build hooks
- tests

Each component should describe its own dependencies and outputs in
`component.yaml`.

## Profile Model

Profiles are declarative selections of components.

Suggested shape:

```yaml
name: server
extends: base
components:
  - networking
  - dropbear
  - nftables
  - cloud-init
  - k3s
```

Properties:

- `base` contains only the minimum shared system
- `server` and `desktop` extend `base`
- profile files do not directly own large sets of implementation files
- implementation details belong inside components

## Builder Responsibility

The builder becomes the source of assembly logic.

Builder responsibilities:

- load a selected profile
- resolve inherited profiles
- resolve selected components
- resolve component dependencies
- validate that all referenced components exist
- merge component contributions into a generated build plan
- execute pipeline stages with clear stage logging

The builder should print stage output in a consistent format such as:

```text
[executing] resolve profile
[executing] merge packages
[executing] merge rootfs
[executing] merge services
[executing] merge kernel config
[executing] build rootfs
[executing] build kernel
[executing] build initramfs
[executing] build iso
```

## Merge Rules

The builder should follow deterministic additive merge rules.

- packages: union with stable ordering and deduplication
- rootfs files: later profile/component override only where explicitly allowed
- s6 services: merge enabled services from selected components
- kernel config: merge config fragments in deterministic order
- hooks: execute by stage in deterministic order
- tests: allow component-level verification

Because profiles are additive only, removal semantics should not exist in the
first version.

## Refactor Direction

This refactor should move the project away from direct hardcoded assembly from:

- `config/`
- `scripts/`
- profile-specific overlay directories

and toward:

- declarative profiles
- encapsulated feature stacks
- generated staging inputs consumed by the builder pipeline

## Important Constraint

Do not organize around generic buckets such as:

- package
- apps
- services
- kernel

Those are artifact types, not encapsulation boundaries.

The correct boundary is the feature stack.

## Expected Outcome

After the refactor:

- profiles are easy to read
- features are reusable across profiles
- dependencies between packages, kernel config, and services stay together
- adding a new feature does not require touching many unrelated directories
- the builder becomes the single place that assembles the final system
