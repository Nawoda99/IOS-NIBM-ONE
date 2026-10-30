import { DataTypes } from 'sequelize';
import { backupTables } from './backup-schema.js';

function dataType(source) {
  const lower = source.toLowerCase(), size = /\((\d+)(?:,(\d+))?\)/.exec(source);
  if (lower.startsWith('enum')) return DataTypes.ENUM(...[...source.matchAll(/'([^']*)'/g)].map(match => match[1]));
  if (lower.startsWith('varchar')) return DataTypes.STRING(Number(size[1]));
  if (lower.startsWith('char')) return DataTypes.CHAR(Number(size[1]));
  if (lower.startsWith('decimal')) return DataTypes.DECIMAL(Number(size[1]), Number(size[2]));
  if (lower.startsWith('tinyint(1)')) return DataTypes.BOOLEAN;
  if (lower.startsWith('tinyint')) return DataTypes.TINYINT;
  if (lower.startsWith('bigint')) return lower.includes('unsigned') ? DataTypes.BIGINT.UNSIGNED : DataTypes.BIGINT;
  if (lower.startsWith('int')) return lower.includes('unsigned') ? DataTypes.INTEGER.UNSIGNED : DataTypes.INTEGER;
  if (lower.startsWith('float')) return DataTypes.FLOAT;
  if (lower.startsWith('datetime') || lower.startsWith('timestamp')) return DataTypes.DATE;
  if (lower === 'date') return DataTypes.DATEONLY;
  if (lower.startsWith('time')) return DataTypes.TIME;
  if (lower === 'json') return DataTypes.JSON;
  if (lower === 'longblob') return DataTypes.BLOB('long');
  if (lower === 'longtext') return DataTypes.TEXT('long');
  if (lower === 'text') return DataTypes.TEXT;
  throw new Error('Unsupported backup column type: ' + source);
}
export function defineModels(sequelize) {
  const models = {};
  for (const { name, ddl } of backupTables) {
    const keys = /PRIMARY KEY \(([^)]+)\)/.exec(ddl)[1];
    const primaryKeys = [...keys.matchAll(/`([^`]+)`/g)].map(match => match[1]);
    const attributes = {};
    for (const line of ddl.split(/\r?\n/)) {
      const match = /^  `([^`]+)` ([a-z]+(?:\([^)]*\))?(?: unsigned)?)(.*)/i.exec(line);
      if (!match) continue;
      attributes[match[1]] = { type: dataType(match[2]), allowNull: !/NOT NULL/.test(match[3]),
        primaryKey: primaryKeys.includes(match[1]), autoIncrement: /AUTO_INCREMENT/.test(match[3]) };
    }
    models[name] = sequelize.define(name, attributes, { tableName: name, timestamps: false, freezeTableName: true });
  }
  return models;
}
