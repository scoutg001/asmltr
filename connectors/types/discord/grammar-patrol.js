'use strict';

/**
 * Grammar Patrol Module for Discord
 * Detects sentences ending with prepositions and responds with a GIF
 */

// Common prepositions that shouldn't end sentences
const PREPOSITIONS = new Set([
  'about', 'above', 'across', 'after', 'against', 'along', 'among', 'around',
  'at', 'before', 'behind', 'below', 'beneath', 'beside', 'between', 'beyond',
  'by', 'down', 'during', 'except', 'for', 'from', 'in', 'inside', 'into',
  'like', 'near', 'of', 'off', 'on', 'outside', 'over', 'since', 'through',
  'throughout', 'till', 'to', 'toward', 'under', 'until', 'up', 'upon',
  'with', 'within', 'without'
]);

// Check if a message ends with a preposition
function endsWithPreposition(text) {
  if (!text || typeof text !== 'string') return false;

  // Clean the text: remove mentions, URLs, emoji, and punctuation
  const cleaned = text
    .replace(/<@!?\d+>/g, '') // Discord mentions
    .replace(/https?:\/\/[^\s]+/g, '') // URLs
    .replace(/:[a-zA-Z0-9_]+:/g, '') // Discord emoji
    .replace(/[^\w\s]/g, ' ') // punctuation to spaces
    .trim();

  if (!cleaned) return false;

  // Split into sentences (crude but effective for Discord messages)
  const sentences = cleaned.split(/[.!?]+/).filter(s => s.trim());
  if (!sentences.length) return false;

  // Check the last complete sentence
  const lastSentence = sentences[sentences.length - 1].trim().toLowerCase();
  const words = lastSentence.split(/\s+/).filter(w => w);

  if (!words.length) return false;

  // Check if the last word is a preposition
  const lastWord = words[words.length - 1];
  return PREPOSITIONS.has(lastWord);
}

// Create the patrol response
function createGrammarResponse(message, gifUrl) {
  return {
    content: `<@${message.author.id}>`,
    embeds: [{
      image: { url: gifUrl },
      color: 0xff0000,
      footer: { text: "Grammar patrol activated" }
    }]
  };
}

// Initialize the grammar patrol
function initGrammarPatrol(config) {
  const enabled = config.grammar_patrol_enabled || false;
  const gifUrl = config.grammar_patrol_gif || 'https://tenor.com/view/oneill-stargate-bastard-grammar-gif-5613606';
  const cooldownMs = config.grammar_patrol_cooldown_ms || 60000; // 1 minute default cooldown
  const exemptRoles = new Set(config.grammar_patrol_exempt_roles || []);
  const targetChannels = new Set(config.grammar_patrol_channels || []); // empty = all channels

  // Track cooldowns per user
  const cooldowns = new Map();

  return {
    enabled,

    async checkMessage(message) {
      if (!enabled) return null;

      // Skip if bot or system message
      if (message.author.bot || message.system) return null;

      // Check channel filter
      if (targetChannels.size > 0 && !targetChannels.has(message.channel.id)) return null;

      // Check role exemptions
      if (message.member && exemptRoles.size > 0) {
        const hasExemptRole = message.member.roles.cache.some(role =>
          exemptRoles.has(role.id) || exemptRoles.has(role.name)
        );
        if (hasExemptRole) return null;
      }

      // Check cooldown
      const userId = message.author.id;
      const lastPatrol = cooldowns.get(userId);
      if (lastPatrol && Date.now() - lastPatrol < cooldownMs) return null;

      // Check for preposition crime
      if (!endsWithPreposition(message.content)) return null;

      // Update cooldown
      cooldowns.set(userId, Date.now());

      // Return the response object
      return createGrammarResponse(message, gifUrl);
    },

    // Clean up old cooldowns periodically
    cleanup() {
      const now = Date.now();
      for (const [userId, timestamp] of cooldowns) {
        if (now - timestamp > cooldownMs * 2) {
          cooldowns.delete(userId);
        }
      }
    }
  };
}

module.exports = { initGrammarPatrol, endsWithPreposition };