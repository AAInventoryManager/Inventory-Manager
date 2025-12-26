export type Tier = 'TIER_1' | 'TIER_2' | 'TIER_3';

export interface MetricVariableDefinition {
  description: string;
  source_tables: string[];
  source_fields?: string[];
  aggregation: string;
  notes?: string;
}

export interface MetricFormulaDefinition {
  expression: string;
}

export interface MetricTimeSemantics {
  type: 'AS_OF' | 'PERIOD_BASED';
  required_dates: string[];
}

export interface MetricOutputDefinition {
  data_type: string;
  precision: number;
  unit: string;
}

export type MetricInputValue =
  | number
  | string
  | null
  | Record<string, unknown>
  | Array<Record<string, unknown>>;

export type MetricExpectedOutput =
  | number
  | string
  | null
  | Record<string, number | string | null>;

export interface MetricTestCase {
  name: string;
  inputs: Record<string, MetricInputValue>;
  expected_output: MetricExpectedOutput;
}

export interface MetricClassificationRule {
  description: string;
  condition?: string;
  cumulative_value_percent_max?: number;
}

export interface MetricThresholdDefinition {
  description: string;
  value: number;
  unit?: string;
}

export interface MetricDefinition {
  metric_id: string;
  display_name: string;
  tier: Tier;
  description: string;
  formula: MetricFormulaDefinition;
  variables: Record<string, MetricVariableDefinition>;
  time_semantics: MetricTimeSemantics;
  dimensions_supported: string[];
  edge_cases: Array<string | Record<string, unknown>>;
  output: MetricOutputDefinition;
  classification_rules?: Record<string, MetricClassificationRule>;
  thresholds?: Record<string, MetricThresholdDefinition>;
  math_operations?: string[];
  tests?: MetricTestCase[];
  audit?: Record<string, string>;
}

export interface MetricExecutionContext {
  period_start?: string;
  period_end?: string;
  as_of_date?: string;
  filters?: Record<string, string | string[]>;
}

export interface MetricExecutionRequest {
  metric_id: string;
  requesting_user_tier: Tier;
  context: MetricExecutionContext;
  inputs: Record<string, MetricInputValue>;
}

export type MetricTimeContext =
  | { type: 'PERIOD_BASED'; period_start: string; period_end: string }
  | { type: 'AS_OF'; as_of_date: string };

export interface MetricExecutionResult {
  metric_id: string;
  value: number | string | null | Record<string, string>;
  unit: string;
  precision: number;
  time_context: MetricTimeContext;
  dimensions_applied: Record<string, string | string[]>;
}
