You are building cross-file associations in a knowledge graph that was just populated with per-file concepts.

# Context

The knowledge graph already contains concepts extracted from individual source files. Within-file relationships were created during extraction. Your job is to create **cross-file relationships** between concepts based on actual code-level dependencies identified from the SCIP code index.

# Cross-File Dependencies

The following file pairs share symbols (functions, types, structs) across file boundaries. For each pair, the shared symbols are listed with their kind and which file defines vs references them.

{relationships}

# Steps

## 1. Find Corresponding Concepts

For each file pair above, use `cog_mem_recall` to find the concepts that were stored from those files. The concept terms should relate to the shared symbols listed.

## 2. Create Associations

Use `cog_mem_associate` with an `items` array to link concepts across files based on the symbol dependencies in a single batch call.

### Predicate Guide

| Dependency Pattern | Predicate |
|-------------------|-----------|
| File A defines a function that File B calls | concept_in_B `requires` concept_in_A |
| File A defines a type that File B uses | concept_in_B `requires` concept_in_A |
| File A implements an interface from File B | concept_in_A `derived_from` concept_in_B |
| Files share a similar pattern | `similar_to` |
| File A is a component of a system in File B | concept_in_A `is_component_of` concept_in_B |
| File A enables functionality in File B | concept_in_A `enables` concept_in_B |

# Guidelines

- **Skip already-connected pairs**: check recall results before creating links
- **Quality over quantity**: 20 precise associations beat 100 vague ones
- **Be specific with predicates**: `requires` and `enables` are more useful than `related_to`
- **Focus on the shared symbols**: they tell you exactly how the files interact
