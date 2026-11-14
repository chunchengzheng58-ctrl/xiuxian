import { type Clock, id, requireCondition } from '../core.js';
import { Database } from '../database.js';
import { Ledger } from './ledger.js';
import { type Character, pixelRarities, pixelRules, pixelSlots } from './rules.js';

const pageSize = 12;
const maxActive = 20;
const maxPrice = 1_000_000;

type Listing = {
  sequence: number; id: string; equipment_id: string; seller_id: string; buyer_id: string | null;
  template: number; rarity_index: number; slot: string; price: number;
  status: 'active' | 'sold' | 'cancelled'; created_at: number; closed_at: number | null; school: number; upgrade_level: number;
};

function publicListing(row: Listing, character: Character) {
  return {
    listing_id: row.id, template: row.template, rarity_index: row.rarity_index, school: row.school, upgrade_level: row.upgrade_level,
    slot: row.slot, price: row.price, status: row.status,
    created_at: row.created_at, closed_at: row.closed_at,
    selling: row.seller_id === character.id, purchased: row.buyer_id === character.id,
  };
}

export class MarketService {
  constructor(private db: Database, private now: Clock, private ledger: Ledger) {}

  list(character: Character, scope: string, slot: string, cursor: number) {
    this.requireSelf(character);
    requireCondition(scope === 'browse' || scope === 'mine', 'INVALID_SCOPE', '交易列表范围无效');
    requireCondition(slot === 'all' || (pixelSlots as readonly string[]).includes(slot), 'INVALID_SLOT', '装备部位无效');
    requireCondition(Number.isSafeInteger(cursor) && cursor >= 0, 'INVALID_CURSOR', '翻页位置无效');
    const scopeCondition = scope === 'browse' ? "status = 'active'" : '(seller_id = ? OR buyer_id = ?)';
    const rows = this.db.all<Listing>(`SELECT * FROM market_listings WHERE ${scopeCondition}
      ${slot === 'all' ? '' : 'AND slot = ?'} ${cursor ? 'AND sequence < ?' : ''}
      ORDER BY sequence DESC LIMIT ?`,
    ...(scope === 'mine' ? [character.id, character.id] : []),
    ...(slot === 'all' ? [] : [slot]), ...(cursor ? [cursor] : []), pageSize + 1);
    return {
      listings: rows.slice(0, pageSize).map(row => publicListing(row, character)),
      next_cursor: rows.length > pageSize ? rows[pageSize - 1]!.sequence : 0,
    };
  }

  post(character: Character, equipmentId: string, price: number) {
    this.requireSelf(character, true);
    requireCondition(Number.isSafeInteger(price) && price >= 1 && price <= maxPrice, 'INVALID_PRICE', '挂单价格须为 1 至 100 万灵气');
    const item = this.db.get<{ catalogue_id: string; catalogue_version: string; slot: string; rarity: string; equipped: number; school: number; upgrade_level: number }>(
      'SELECT * FROM equipment WHERE id = ? AND cultivator_id = ? AND salvaged_at IS NULL', equipmentId, character.id);
    requireCondition(item, 'NOT_FOUND', '装备不存在或不属于当前角色', 404);
    const match = /^pixel:(\d+)$/.exec(item.catalogue_id);
    const template = match ? Number(match[1]) : -1;
    const rarity = (pixelRarities as readonly string[]).indexOf(item.rarity);
    requireCondition(item.catalogue_version === pixelRules.catalogue_version && pixelRules.templates[template]?.slot === item.slot && rarity >= 0,
      'EQUIPMENT_UNTRADEABLE', '这件装备暂不可交易', 409);
    requireCondition(!item.equipped, 'EQUIPMENT_EQUIPPED', '请先卸下装备再上架', 409);
    requireCondition(!this.db.get("SELECT id FROM market_listings WHERE equipment_id = ? AND status = 'active'", equipmentId),
      'EQUIPMENT_LISTED', '这件装备已在售', 409);
    const active = this.db.get<{ count: number }>("SELECT COUNT(*) AS count FROM market_listings WHERE seller_id = ? AND status = 'active'", character.id)!.count;
    requireCondition(active < maxActive, 'LISTING_LIMIT', '最多同时上架 20 件装备', 409);
    const listingId = id('listing');
    this.db.run(`INSERT INTO market_listings (id, equipment_id, seller_id, template, rarity_index, slot, price, created_at, school, upgrade_level)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, listingId, equipmentId, character.id, template, rarity, item.slot, price, this.now(), item.school, item.upgrade_level);
    this.db.touch(character.account_id);
    return publicListing(this.get(listingId), character);
  }

  cancel(character: Character, listingId: string) {
    this.requireSelf(character);
    const listing = this.get(listingId);
    requireCondition(listing.seller_id === character.id, 'NOT_FOUND', '未找到你的挂单', 404);
    requireCondition(listing.status === 'active', 'LISTING_CLOSED', '挂单已结束，请刷新交易列表', 409);
    this.db.run("UPDATE market_listings SET status = 'cancelled', closed_at = ? WHERE id = ?", this.now(), listingId);
    this.db.touch(character.account_id);
    return publicListing(this.get(listingId), character);
  }

  buy(character: Character, listingId: string) {
    this.requireSelf(character, true);
    const listing = this.get(listingId);
    requireCondition(listing.status === 'active', 'LISTING_CLOSED', '挂单已结束，请刷新交易列表', 409);
    const seller = this.db.get<{ account_id: string }>('SELECT account_id FROM cultivators WHERE id = ?', listing.seller_id)!;
    requireCondition(seller.account_id !== character.account_id, 'SELF_TRADE', '不能购买本账号上架的装备', 409);
    // 共享命令的幂等事务包住装备、买卖双方的流水及成交状态。
    const transferred = this.db.run('UPDATE equipment SET cultivator_id = ? WHERE id = ? AND cultivator_id = ? AND equipped = 0 AND salvaged_at IS NULL',
      character.id, listing.equipment_id, listing.seller_id);
    requireCondition(transferred.changes === 1, 'EQUIPMENT_UNAVAILABLE', '这件装备已经无法交付', 409);
    this.ledger.change(character.account_id, character.id, 'spirit_stones', -listing.price, `market:${listingId}:buy`, 'market_buy');
    this.ledger.change(seller.account_id, listing.seller_id, 'spirit_stones', listing.price, `market:${listingId}:sell`, 'market_sell');
    this.db.run("UPDATE market_listings SET status = 'sold', buyer_id = ?, closed_at = ? WHERE id = ?", character.id, this.now(), listingId);
    this.db.touch(character.account_id);
    this.db.touch(seller.account_id);
    return publicListing(this.get(listingId), character);
  }

  private requireSelf(character: Character, write = false) {
    requireCondition(character.role === 'self', 'MARKET_SELF_REQUIRED', '请切换到本人角色使用万宝集', 403);
    requireCondition(!write || character.lifecycle !== 'ascended', 'ACTION_UNAVAILABLE', '当前角色无法发起交易', 409);
  }

  private get(listingId: string) {
    const listing = this.db.get<Listing>('SELECT * FROM market_listings WHERE id = ?', listingId);
    requireCondition(listing, 'NOT_FOUND', '挂单不存在', 404);
    return listing;
  }
}
