# Table Column Model

## Purpose
Define how table columns are represented for UI configuration, including
opinionated defaults and optional columns per table.

## What Is a Table Column
A table column is a user-visible representation of a specific data field or
computed value within a single table view (table-scoped). Column configuration
controls presentation only and does not change underlying data.

## Table-Scoped Configuration
Column configurations are scoped to a specific table identifier, for example:
- inventory_list
- purchase_orders
- jobs

## Column Attributes
Each column definition includes:
- key: Stable internal identifier used for configuration and telemetry.
- label: Human-readable display name shown in the UI.
- visibility: Default on/off state in the table's default configuration.
- lock: When true, the column cannot be hidden.

## Default vs Optional Columns
- Default columns are visible for all new users on first use.
- Optional columns are available but hidden by default; users may show them.

## Anchor Column Rule
At least one identifying column per table (for example, Item Name) must be
visible at all times. Anchor columns are locked and cannot be hidden.

## Default Principle
Default columns must satisfy at least 80% of typical user needs for the table.
