const amqp = require("amqplib");
const { rabbit } = require("./config");

let conn = null;
let ch = null;

async function getChannel() {
  if (ch) return ch;
  conn = await amqp.connect(rabbit.url);
  ch = await conn.createChannel();
  await ch.assertExchange(rabbit.exchange, "topic", { durable: true });
  return ch;
}

async function publish(routingKey, payload) {
  const channel = await getChannel();
  channel.publish(
    rabbit.exchange,
    routingKey,
    Buffer.from(JSON.stringify(payload)),
    { persistent: true }
  );
}

module.exports = { publish };
