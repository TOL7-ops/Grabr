const { createLogger, format, transports } = require("winston");
const config = require("../config");

const logger = createLogger({
  level: config.nodeEnv === "production" ? "info" : "debug",
  format: format.combine(
    format.timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
    format.errors({ stack: true }),
    config.nodeEnv === "production"
      ? format.json()
      : format.combine(
          format.colorize(),
          format.printf(({ timestamp, level, message, ...meta }) => {
            const extras = Object.keys(meta).length ? ` ${JSON.stringify(meta)}` : "";
            return `${timestamp} [${level}]: ${message}${extras}`;
          })
        )
  ),
  transports: [
    new transports.Console(),
    ...(config.nodeEnv === "production"
      ? [
          new transports.File({ filename: "logs/error.log", level: "error" }),
          new transports.File({ filename: "logs/combined.log" }),
        ]
      : []),
  ],
});

module.exports = logger;