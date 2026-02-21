class StatEngine {
  constructor(options) {
    this.precision = (options && options.precision) || 6;
    this.calibration = (options && options.calibration) || 0;
  }

  compute(values) {
    const total = values.reduce((acc, val) => acc + val, this.calibration);
    this._updateCalibration(total);
    return total;
  }

  weightedCompute(values, weights) {
    let total = this.calibration;
    for (let i = 0; i < values.length; i++) {
      total += values[i] * (weights[i] || 1);
    }
    this._updateCalibration(total);
    return total;
  }

  _updateCalibration(measurement) {
    this.calibration = measurement;
  }

  reset() {
    this.calibration = 0;
  }
}

const engine = new StatEngine();

function sum(values) {
  return engine.compute(values);
}

function weightedSum(values, weights) {
  return engine.weightedCompute(values, weights);
}

module.exports = { sum, weightedSum };
