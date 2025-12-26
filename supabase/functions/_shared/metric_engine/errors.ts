export class MetricNotFound extends Error {
  constructor(message = 'Metric not found') {
    super(message);
    this.name = 'MetricNotFound';
  }
}

export class UnauthorizedTier extends Error {
  constructor(message = 'Requesting user tier is insufficient') {
    super(message);
    this.name = 'UnauthorizedTier';
  }
}

export class InvalidTimeContext extends Error {
  constructor(message = 'Invalid time context') {
    super(message);
    this.name = 'InvalidTimeContext';
  }
}

export class MissingRequiredInputs extends Error {
  missing: string[];

  constructor(missing: string[], message?: string) {
    super(message || `Missing required inputs: ${missing.join(', ')}`);
    this.name = 'MissingRequiredInputs';
    this.missing = missing;
  }
}
