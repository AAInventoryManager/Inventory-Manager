import { evaluateExpression } from './expression.ts';
import {
  InvalidTimeContext,
  MetricNotFound,
  MissingRequiredInputs,
  UnauthorizedTier,
} from './errors.ts';
import type {
  MetricClassificationRule,
  MetricDefinition,
  MetricExecutionRequest,
  MetricExecutionResult,
  MetricExecutionContext,
  MetricTimeContext,
  MetricInputValue,
  MetricVariableDefinition,
  Tier,
} from './types.ts';
import { MetricRegistry } from './registry.ts';

const tierRank: Record<Tier, number> = {
  TIER_1: 1,
  TIER_2: 2,
  TIER_3: 3,
};

interface EdgeCaseRule {
  variable: string;
  equals: number;
  returnValue: number | null;
}

export class MetricExecutionService {
  constructor(private registry: MetricRegistry) {}

  execute(request: MetricExecutionRequest): MetricExecutionResult {
    if (!request.metric_id) {
      throw new MissingRequiredInputs(['metric_id']);
    }

    if (!request.requesting_user_tier) {
      throw new MissingRequiredInputs(['requesting_user_tier']);
    }

    const metric = this.registry.get(request.metric_id);
    if (!metric) {
      throw new MetricNotFound(`Metric not found: ${request.metric_id}`);
    }

    if (!isTierAuthorized(request.requesting_user_tier, metric.tier)) {
      throw new UnauthorizedTier(
        `Tier ${request.requesting_user_tier} is insufficient for ${metric.metric_id}`
      );
    }

    const timeContext = resolveTimeContext(metric, request.context);

    const value = executeFormula(metric, request.inputs);

    return {
      metric_id: metric.metric_id,
      value,
      unit: metric.output.unit,
      precision: metric.output.precision,
      time_context: timeContext,
      dimensions_applied: resolveDimensions(metric, request.context.filters),
    };
  }
}

function executeFormula(
  metric: MetricDefinition,
  inputs: Record<string, MetricInputValue>
): number | string | null | Record<string, string> {
  switch (metric.formula.expression) {
    case 'MOVEMENT_CLASSIFICATION': {
      const { variableValues } = resolveVariableValues(metric, inputs);
      return executeMovementClassification(metric, variableValues);
    }
    case 'ABC_CLASSIFICATION': {
      return executeABCClassification(metric, inputs);
    }
    default: {
      const { variableValues } = resolveVariableValues(metric, inputs);
      const edgeCaseResult = applyEdgeCases(metric.edge_cases, variableValues);
      const value = edgeCaseResult.applied
        ? edgeCaseResult.value
        : evaluateExpression(metric.formula.expression, variableValues);
      return value !== null ? applyPrecision(value, metric.output.precision) : value;
    }
  }
}

function isTierAuthorized(requested: Tier, required: Tier): boolean {
  const requestedRank = tierRank[requested];
  const requiredRank = tierRank[required];
  if (!requestedRank || !requiredRank) {
    return false;
  }
  return requestedRank >= requiredRank;
}

function resolveTimeContext(
  metric: MetricDefinition,
  context: MetricExecutionContext
): MetricTimeContext {
  if (!context) {
    throw new InvalidTimeContext('Missing time context');
  }

  const requiredDates = Array.isArray(metric.time_semantics.required_dates)
    ? metric.time_semantics.required_dates
    : [];

  const missing = requiredDates.filter((key) => !getContextValue(context, key));
  if (missing.length > 0) {
    throw new InvalidTimeContext(`Missing required time inputs: ${missing.join(', ')}`);
  }

  if (metric.time_semantics.type === 'PERIOD_BASED') {
    const periodStart = getContextValue(context, 'period_start');
    const periodEnd = getContextValue(context, 'period_end');
    if (!periodStart || !periodEnd) {
      throw new InvalidTimeContext('Missing period_start or period_end');
    }
    return {
      type: 'PERIOD_BASED',
      period_start: periodStart,
      period_end: periodEnd,
    };
  }

  if (metric.time_semantics.type === 'AS_OF') {
    const asOfDate = getContextValue(context, 'as_of_date');
    if (!asOfDate) {
      throw new InvalidTimeContext('Missing as_of_date');
    }
    return {
      type: 'AS_OF',
      as_of_date: asOfDate,
    };
  }

  throw new InvalidTimeContext(`Unsupported time semantics: ${metric.time_semantics.type}`);
}

function getContextValue(context: MetricExecutionContext, key: string): string | null {
  const raw = (context as Record<string, unknown>)[key];
  if (typeof raw !== 'string') {
    return null;
  }
  const trimmed = raw.trim();
  return trimmed ? trimmed : null;
}

function resolveVariableValues(
  metric: MetricDefinition,
  inputs: Record<string, MetricInputValue>
): { variableValues: Record<string, number> } {
  if (!inputs || typeof inputs !== 'object') {
    throw new MissingRequiredInputs(Object.keys(metric.variables));
  }

  const numericInputs = extractNumericInputs(inputs);
  const variableValues: Record<string, number> = {};
  const missing: string[] = [];

  for (const [name, definition] of Object.entries(metric.variables)) {
    const directValue = numericInputs[name];
    if (directValue !== undefined) {
      variableValues[name] = directValue;
      continue;
    }

    if (definition.aggregation === 'DERIVED') {
      const derivedValue = resolveDerivedVariable(name, definition, numericInputs);
      if (derivedValue === null) {
        missing.push(name);
      } else {
        variableValues[name] = derivedValue;
      }
      continue;
    }

    missing.push(name);
  }

  if (missing.length > 0) {
    throw new MissingRequiredInputs(missing);
  }

  return { variableValues };
}

function extractNumericInputs(inputs: Record<string, MetricInputValue>): Record<string, number> {
  const numericInputs: Record<string, number> = {};
  for (const [key, value] of Object.entries(inputs)) {
    if (typeof value === 'number' && Number.isFinite(value)) {
      numericInputs[key] = value;
    }
  }
  return numericInputs;
}

function resolveDerivedVariable(
  name: string,
  definition: MetricVariableDefinition,
  inputs: Record<string, number>
): number | null {
  const expression = extractDerivedExpression(definition.notes);
  if (!expression) {
    return null;
  }
  try {
    return evaluateExpression(expression, inputs);
  } catch (error) {
    if (error instanceof MissingRequiredInputs) {
      throw error;
    }
    throw new MissingRequiredInputs([name]);
  }
}

function extractDerivedExpression(notes?: string): string | null {
  if (!notes) {
    return null;
  }
  const match = notes.match(/Calculated as\s+(.+?)(?:\.|$)/i);
  if (!match) {
    return null;
  }
  return match[1].trim();
}

function executeMovementClassification(
  metric: MetricDefinition,
  variableValues: Record<string, number>
): string {
  const quantityMoved = variableValues.QuantityMoved;
  const daysObserved = variableValues.DaysObserved;

  if (!Number.isFinite(quantityMoved) || !Number.isFinite(daysObserved)) {
    throw new MissingRequiredInputs(['QuantityMoved', 'DaysObserved']);
  }

  if (daysObserved === 0) {
    return 'UNKNOWN';
  }

  const adjustedQuantityMoved = quantityMoved < 0 ? 0 : quantityMoved;
  if (adjustedQuantityMoved === 0) {
    return 'DEAD';
  }

  const thresholds = metric.thresholds;
  if (!thresholds?.fast_threshold || typeof thresholds.fast_threshold.value !== 'number') {
    throw new Error('Missing fast_threshold configuration');
  }

  const averageDailyMovement = adjustedQuantityMoved / daysObserved;
  const context: Record<string, number> = {
    average_daily_movement: averageDailyMovement,
    fast_threshold: thresholds.fast_threshold.value,
  };

  const rules = metric.classification_rules;
  if (!rules || typeof rules !== 'object') {
    throw new Error('Missing classification_rules configuration');
  }

  for (const [key, rule] of Object.entries(rules)) {
    if (evaluateClassificationCondition(rule, context)) {
      return key.toUpperCase();
    }
  }

  return 'UNKNOWN';
}

function evaluateClassificationCondition(
  rule: MetricClassificationRule,
  context: Record<string, number>
): boolean {
  if (!rule.condition) {
    throw new Error('Missing classification rule condition');
  }
  const conditions = rule.condition.split(/\s+AND\s+/i).map((segment) => segment.trim());
  return conditions.every((segment) => evaluateComparison(segment, context));
}

function evaluateComparison(segment: string, context: Record<string, number>): boolean {
  const match = segment.match(
    /^([A-Za-z0-9_]+)\s*(>=|<=|==|>|<)\s*([A-Za-z0-9_.+-]+)$/
  );
  if (!match) {
    throw new Error(`Unsupported classification condition: ${segment}`);
  }

  const leftValue = resolveClassificationToken(match[1], context);
  const rightValue = resolveClassificationToken(match[3], context);

  switch (match[2]) {
    case '>':
      return leftValue > rightValue;
    case '>=':
      return leftValue >= rightValue;
    case '<':
      return leftValue < rightValue;
    case '<=':
      return leftValue <= rightValue;
    case '==':
      return leftValue === rightValue;
    default:
      return false;
  }
}

function resolveClassificationToken(token: string, context: Record<string, number>): number {
  if (Object.prototype.hasOwnProperty.call(context, token)) {
    return context[token];
  }
  const numeric = Number(token);
  if (!Number.isFinite(numeric)) {
    throw new Error(`Unsupported classification token: ${token}`);
  }
  return numeric;
}

function executeABCClassification(
  metric: MetricDefinition,
  inputs: Record<string, MetricInputValue>
): Record<string, string> {
  const records = inputs.records;
  if (!Array.isArray(records)) {
    throw new MissingRequiredInputs(['records']);
  }

  const rankedItems: Array<{ item: string; value: number }> = [];

  for (const record of records) {
    if (!record || typeof record !== 'object') {
      throw new MissingRequiredInputs(['records']);
    }

    const item = (record as Record<string, unknown>).item;
    if (typeof item !== 'string' || !item.trim()) {
      throw new MissingRequiredInputs(['item']);
    }

    const annualUsage = (record as Record<string, unknown>).AnnualUsageQuantity;
    if (typeof annualUsage !== 'number' || !Number.isFinite(annualUsage)) {
      throw new MissingRequiredInputs(['AnnualUsageQuantity']);
    }
    if (annualUsage === 0) {
      continue;
    }

    const unitCost = (record as Record<string, unknown>).UnitCost;
    if (typeof unitCost !== 'number' || !Number.isFinite(unitCost)) {
      continue;
    }

    rankedItems.push({ item, value: annualUsage * unitCost });
  }

  if (rankedItems.length === 0) {
    return {};
  }

  const totalValue = rankedItems.reduce((sum, item) => sum + item.value, 0);

  if (totalValue === 0) {
    return rankedItems.reduce<Record<string, string>>((acc, item) => {
      acc[item.item] = 'C';
      return acc;
    }, {});
  }

  const rules = metric.classification_rules;
  if (!rules || typeof rules !== 'object') {
    throw new Error('Missing classification_rules configuration');
  }

  const thresholds = Object.entries(rules).map(([key, rule]) => {
    if (typeof rule.cumulative_value_percent_max !== 'number') {
      throw new Error(`Missing cumulative_value_percent_max for ${key}`);
    }
    return { key, max: rule.cumulative_value_percent_max };
  });

  thresholds.sort((a, b) => a.max - b.max);

  rankedItems.sort((a, b) => {
    const diff = b.value - a.value;
    if (diff !== 0) {
      return diff;
    }
    return a.item.localeCompare(b.item);
  });

  const assignments: Array<{ item: string; classification: string }> = [];
  const classCounts: Record<string, number> = {};
  let cumulative = 0;

  for (const item of rankedItems) {
    cumulative += item.value;
    const cumulativePercent = (cumulative / totalValue) * 100;
    const rule = thresholds.find((threshold) => cumulativePercent <= threshold.max);
    const classification = rule ? rule.key : thresholds[thresholds.length - 1].key;
    assignments.push({ item: item.item, classification });
    classCounts[classification] = (classCounts[classification] || 0) + 1;
  }

  const classOrder = thresholds.map((threshold) => threshold.key);
  const classMapping: Record<string, string> = {};
  let nextIndex = 0;

  for (const classKey of classOrder) {
    if (classCounts[classKey]) {
      classMapping[classKey] = classOrder[nextIndex];
      nextIndex += 1;
    }
  }

  const result = assignments.reduce<Record<string, string>>((acc, entry) => {
    acc[entry.item] = classMapping[entry.classification] || entry.classification;
    return acc;
  }, {});

  return result;
}

function parseEdgeCaseRule(edgeCase: string | Record<string, unknown>): EdgeCaseRule | null {
  const text = typeof edgeCase === 'string' ? edgeCase : JSON.stringify(edgeCase);
  const match = text.match(
    /if\s+([A-Za-z0-9_]+)\s+equals\s+([+-]?[0-9]+(?:\.[0-9]+)?)\s*,?\s*return\s+([A-Za-z0-9_.+-]+)/i
  );
  if (!match) {
    return null;
  }

  const variable = match[1];
  const equals = Number(match[2]);
  const rawReturn = match[3];
  const normalizedReturn = rawReturn.replace(/[).,]+$/g, '');

  if (!Number.isFinite(equals)) {
    return null;
  }

  if (normalizedReturn.toUpperCase() === 'NULL') {
    return { variable, equals, returnValue: null };
  }

  const returnValue = Number(normalizedReturn);
  if (!Number.isFinite(returnValue)) {
    return null;
  }

  return { variable, equals, returnValue };
}

function applyEdgeCases(
  edgeCases: Array<string | Record<string, unknown>>,
  variableValues: Record<string, number>
): { applied: boolean; value: number | null } {
  for (const edgeCase of edgeCases) {
    const rule = parseEdgeCaseRule(edgeCase);
    if (!rule) {
      throw new Error(`Unsupported edge case format: ${String(edgeCase)}`);
    }

    if (!Object.prototype.hasOwnProperty.call(variableValues, rule.variable)) {
      throw new MissingRequiredInputs([rule.variable]);
    }

    if (variableValues[rule.variable] === rule.equals) {
      return { applied: true, value: rule.returnValue };
    }
  }

  return { applied: false, value: null };
}

function applyPrecision(value: number, precision: number): number {
  const factor = 10 ** precision;
  return Math.round(value * factor) / factor;
}

function resolveDimensions(
  metric: MetricDefinition,
  filters: MetricExecutionContext['filters']
): Record<string, string | string[]> {
  const applied: Record<string, string | string[]> = {};
  if (!filters) {
    return applied;
  }
  const supported = new Set(metric.dimensions_supported || []);
  for (const [key, value] of Object.entries(filters)) {
    if (supported.has(key)) {
      applied[key] = value;
    }
  }
  return applied;
}
