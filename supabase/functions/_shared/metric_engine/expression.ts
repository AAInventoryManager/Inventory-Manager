import { MissingRequiredInputs } from './errors.ts';

interface Token {
  type: 'number' | 'identifier' | 'operator' | 'paren';
  value: string;
}

const operatorPrecedence: Record<string, number> = {
  '+': 1,
  '-': 1,
  '*': 2,
  '/': 2,
};

function isIdentifierStart(char: string): boolean {
  return /[A-Za-z_]/.test(char);
}

function isIdentifierChar(char: string): boolean {
  return /[A-Za-z0-9_]/.test(char);
}

function isNumberChar(char: string): boolean {
  return /[0-9.]/.test(char);
}

function tokenizeExpression(expression: string): Token[] {
  const tokens: Token[] = [];
  let index = 0;
  let prevType: Token['type'] | null = null;

  while (index < expression.length) {
    const char = expression[index];

    if (/\s/.test(char)) {
      index += 1;
      continue;
    }

    if (isIdentifierStart(char)) {
      const start = index;
      index += 1;
      while (index < expression.length && isIdentifierChar(expression[index])) {
        index += 1;
      }
      tokens.push({ type: 'identifier', value: expression.slice(start, index) });
      prevType = 'identifier';
      continue;
    }

    if (isNumberChar(char)) {
      const start = index;
      index += 1;
      while (index < expression.length && isNumberChar(expression[index])) {
        index += 1;
      }
      tokens.push({ type: 'number', value: expression.slice(start, index) });
      prevType = 'number';
      continue;
    }

    if (char === '(' || char === ')') {
      tokens.push({ type: 'paren', value: char });
      prevType = 'paren';
      index += 1;
      continue;
    }

    if (char === '+' || char === '-' || char === '*' || char === '/') {
      if (
        char === '-' &&
        (prevType === null || prevType === 'operator' || (prevType === 'paren' && tokens[tokens.length - 1]?.value === '('))
      ) {
        tokens.push({ type: 'number', value: '0' });
      }
      tokens.push({ type: 'operator', value: char });
      prevType = 'operator';
      index += 1;
      continue;
    }

    throw new Error(`Invalid character in expression: ${char}`);
  }

  return tokens;
}

function toRpn(tokens: Token[]): Token[] {
  const output: Token[] = [];
  const operators: Token[] = [];

  for (const token of tokens) {
    if (token.type === 'number' || token.type === 'identifier') {
      output.push(token);
      continue;
    }

    if (token.type === 'operator') {
      while (operators.length > 0) {
        const top = operators[operators.length - 1];
        if (top.type !== 'operator') break;
        if (operatorPrecedence[top.value] >= operatorPrecedence[token.value]) {
          output.push(operators.pop() as Token);
          continue;
        }
        break;
      }
      operators.push(token);
      continue;
    }

    if (token.type === 'paren' && token.value === '(') {
      operators.push(token);
      continue;
    }

    if (token.type === 'paren' && token.value === ')') {
      let matched = false;
      while (operators.length > 0) {
        const op = operators.pop() as Token;
        if (op.type === 'paren' && op.value === '(') {
          matched = true;
          break;
        }
        output.push(op);
      }
      if (!matched) {
        throw new Error('Mismatched parentheses in expression');
      }
    }
  }

  while (operators.length > 0) {
    const op = operators.pop() as Token;
    if (op.type === 'paren') {
      throw new Error('Mismatched parentheses in expression');
    }
    output.push(op);
  }

  return output;
}

export function evaluateExpression(
  expression: string,
  variables: Record<string, number>
): number {
  const tokens = tokenizeExpression(expression);
  const rpn = toRpn(tokens);
  const stack: number[] = [];

  for (const token of rpn) {
    if (token.type === 'number') {
      const value = Number(token.value);
      if (!Number.isFinite(value)) {
        throw new Error(`Invalid number in expression: ${token.value}`);
      }
      stack.push(value);
      continue;
    }

    if (token.type === 'identifier') {
      if (!Object.prototype.hasOwnProperty.call(variables, token.value)) {
        throw new MissingRequiredInputs([token.value]);
      }
      const value = variables[token.value];
      if (!Number.isFinite(value)) {
        throw new MissingRequiredInputs([token.value]);
      }
      stack.push(value);
      continue;
    }

    if (token.type === 'operator') {
      const right = stack.pop();
      const left = stack.pop();
      if (left === undefined || right === undefined) {
        throw new Error('Invalid expression evaluation');
      }
      switch (token.value) {
        case '+':
          stack.push(left + right);
          break;
        case '-':
          stack.push(left - right);
          break;
        case '*':
          stack.push(left * right);
          break;
        case '/':
          stack.push(left / right);
          break;
        default:
          throw new Error(`Unsupported operator: ${token.value}`);
      }
    }
  }

  if (stack.length !== 1) {
    throw new Error('Invalid expression evaluation');
  }

  return stack[0];
}
