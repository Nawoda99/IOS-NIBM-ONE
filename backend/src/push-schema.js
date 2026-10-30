// Additive app tables; the imported backup tables remain unchanged.
export const pushTables = [{ name: 'ios_push_devices', ddl: `CREATE TABLE \`ios_push_devices\` (
  \`token\` varchar(512) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  \`environment\` enum('sandbox','production') NOT NULL,
  \`employeeId\` int NOT NULL,
  \`sessionId\` char(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  \`updatedAt\` datetime(3) NOT NULL,
  PRIMARY KEY (\`token\`,\`environment\`),
  KEY \`ios_push_employee\` (\`employeeId\`),
  KEY \`ios_push_session\` (\`sessionId\`),
  CONSTRAINT \`ios_push_employee_fk\` FOREIGN KEY (\`employeeId\`) REFERENCES \`employees\` (\`id\`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT \`ios_push_session_fk\` FOREIGN KEY (\`sessionId\`) REFERENCES \`login_devices\` (\`id\`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;` }];
