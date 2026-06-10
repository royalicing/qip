# Why QIP Exists

QIP prefers small executable boundaries because self-contained components are easier to reason about than whole captured environments.

The homepage gives the short version. This page explains the design pressure behind it: modern software is expressive, but ordinary code often depends on ambient state that is hard to reproduce precisely.

## The Problem With Software Today

Much software is built as layers of frameworks, packages, platforms, and operating-system features. The result is often non-deterministic in practice: behavior can depend on installed packages, environment variables, filesystem layout, network services, clocks, and the exact shape of the runtime around it.

Containers help by packaging that environment, but they also preserve the assumption that a small piece of logic needs a large surrounding world. That can be the right tradeoff for full applications, but it is often more machinery than a content transform, validator, image filter, or small interactive tool needs.

AI coding raises the stakes. Agents can generate useful code quickly, but generated code is easier to evaluate when the runtime boundary is small, explicit, and repeatable.

## The QIP Values

QIP is named for the constraints we want every component to keep:

- **Quarantined:** components run in a deterministic sandbox with zero access to the host: no filesystem, no network, and no environment.
- **Immutable:** components are self-contained with no required dependencies, so once you have a working component it keeps working with no updates required.
- **Portable:** components run identically across web and native hosts through the same QIP contract.

## Why WebAssembly

WebAssembly gives QIP a compact, portable execution target.

A QIP component is a WebAssembly binary with explicit imports and exports. By default, QIP gives it no filesystem, network, environment, clock, or secrets. The host writes input bytes into component memory, calls a known export such as `render(input_size)`, then reads output bytes back.

That shape gives the host a deterministic execution boundary: the same component bytes and input bytes are guaranteed to produce the same output bytes. Components stay small enough to test, benchmark, and replace when better code appears.

## Why Not WASI

WASI is useful when a program needs operating-system-like capabilities. QIP is deliberately narrower.

For QIP components, the default should be no ambient host access. If a component transforms Markdown, validates UTF-8, renders an image tile, or emits an interactive frame, it should not need file descriptors, sockets, environment variables, or a virtual filesystem.

This smaller contract is less general, but it is easier to run in browsers, easier to inspect, and easier to explain to coding agents.

## Content-First, Not File-First

QIP treats content as bytes with media types, not as files with special build-system meaning.

That is why recipes are selected by MIME type, why Content components can convert/assert/refine a pipeline, and why router output can be represented as `application/warc` instead of a particular static-file layout.

For example, `qip router warc ./site` produces a Web Archive. Another component can turn that archive into a static tarball, check links, add derived metadata, or prepare it for a deployment target.

## The Tradeoff

QIP is not trying to be a package manager, app framework, or general-purpose operating-system interface.

Use QIP when you want:

- small components with explicit input and output
- deterministic component pipelines
- sandboxed generated components
- browser/server/native portability
- content transforms that are easy to inspect

Do not use QIP when the core requirement is long-lived external state, broad system access, or a dependency-rich application runtime.
