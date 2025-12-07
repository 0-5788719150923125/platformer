# Hashing

Deterministic namespace generation for parallel deployments.

## Origin Story

This module was born from a friendly disagreement: Dan hates infrastructure with pet names, while Andrew invests in Pokemon memorabilia. The module name "hashing" is a playful nod to Melanie (MJ) - and a reference that works on multiple levels. What started as a joke is now a production-ready system for generating stable, deterministic deployment identifiers.

## Purpose

To enable multiple instances of the same infrastructure to coexist without resource name collisions.

## Algorithms

**pet** - Random adjective-animal pairs (e.g., `happy-dog`)

**pokeform** - Markov chain generator trained on Pokemon names (e.g., `pikatle`)

Both algorithms are deterministically seeded. The same seed always produces the same namespace, enabling predictable deployments.

## Extensibility

Adding new algorithms is straightforward: create a generator script, add static data if needed, update validation. The module automatically calls new generators with the seed value.
