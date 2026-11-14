import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from '../contracts.js';
import { type Clock, id, requireCondition } from '../core.js';
import { Database } from '../database.js';
import { Ledger } from './ledger.js';
import { type Character, pixelRules, pixelRarities } from './rules.js';

type Bonuses = Partial<Record<'life' | 'attack' | 'defense' | 'spirit' | 'stamina', number>>;
type GrowthConfig = {
  version: string; max_level: number; upgrade_percent_per_level: number; upgrade_flat_per_level: number;
  upgrade_materials_per_level: number; upgrade_qi_per_level: number;
  attune_materials: number; attune_qi: number; salvage_base: number[];
  legendary_soft_start: number; legendary_soft_step: number; legendary_hard: number;
  schools: { name: string; color: string; two: Bonuses; four: Bonuses }[];
};
export const growthConfig = JSON.parse(readFileSync(join(repositoryRoot, 'data/equipment-growth.v2.json'), 'utf8')) as GrowthConfig;
export type GrowingEquipment = {
  id: string; catalogue_id: string; catalogue_version: string; rarity: string;
  equipped: number; school: number; upgrade_level: number;
};

export function upgradeCost(level: number) {
  return { materials: growthConfig.upgrade_materials_per_level * (level + 1), qi: growthConfig.upgrade_qi_per_level * (level + 1) };
}
export function salvageYield(item: GrowingEquipment) {
  const base = growthConfig.salvage_base[(pixelRarities as readonly string[]).indexOf(item.rarity)]!;
  const invested = growthConfig.upgrade_materials_per_level * item.upgrade_level * (item.upgrade_level + 1) / 2;
  return base + Math.floor(invested / 2);
}
export function equipmentBonuses(items: GrowingEquipment[]) {
  const bonuses = { life: 0, attack: 0, defense: 0, spirit: 0, stamina: 0 };
  const counts = growthConfig.schools.map(() => 0);
  for (const item of items) {
    if (!item.equipped || item.catalogue_version !== pixelRules.catalogue_version) continue;
    const template = pixelRules.templates[Number(item.catalogue_id.slice('pixel:'.length))];
    const rarity = (pixelRarities as readonly string[]).indexOf(item.rarity);
    if (!template || rarity < 0) continue;
    bonuses[template.stat] += Math.floor(template.values[rarity]! * (100 + item.upgrade_level * growthConfig.upgrade_percent_per_level) / 100)
      + item.upgrade_level * growthConfig.upgrade_flat_per_level;
    if (item.school >= 0) counts[item.school]!++;
  }
  for (let school = 0; school < counts.length; school++) {
    const rules = growthConfig.schools[school]!;
    for (const extra of [counts[school]! >= 2 ? rules.two : {}, counts[school]! >= 4 ? rules.four : {}]) {
      for (const [stat, value] of Object.entries(extra)) bonuses[stat as keyof typeof bonuses] += value;
    }
  }
  return bonuses;
}

export class EquipmentGrowth {
  constructor(private db: Database, private ledger: Ledger, private now: Clock) {}

  upgrade(actor: Character, equipmentId: string, expected: number) {
    const item = this.available(actor, equipmentId);
    requireCondition(Number.isSafeInteger(expected) && item.upgrade_level === expected, 'EQUIPMENT_CHANGED', '装备等级已变化，请刷新后再试', 409);
    requireCondition(item.upgrade_level < growthConfig.max_level, 'EQUIPMENT_MAX_LEVEL', '装备已达到强化上限', 409);
    const cost = upgradeCost(item.upgrade_level);
    this.spend(actor, cost.materials, cost.qi, 'equipment_upgrade');
    this.db.run('UPDATE equipment SET upgrade_level = upgrade_level + 1 WHERE id = ?', equipmentId);
    this.db.touch(actor.account_id);
  }

  attune(actor: Character, equipmentId: string, school: number, expected: number) {
    const item = this.available(actor, equipmentId);
    requireCondition(Number.isSafeInteger(school) && school >= 0 && school < growthConfig.schools.length, 'INVALID_SCHOOL', '铭刻流派无效');
    requireCondition(item.school === expected, 'EQUIPMENT_CHANGED', '装备铭刻已变化，请刷新后再试', 409);
    requireCondition(item.school !== school, 'EQUIPMENT_SAME_SCHOOL', '装备已拥有这个流派铭刻', 409);
    this.spend(actor, growthConfig.attune_materials, growthConfig.attune_qi, 'equipment_attune');
    this.db.run('UPDATE equipment SET school = ? WHERE id = ?', school, equipmentId);
    this.db.touch(actor.account_id);
  }

  salvage(actor: Character, equipmentId: string) {
    const item = this.available(actor, equipmentId);
    requireCondition(!item.equipped, 'EQUIPMENT_EQUIPPED', '请先卸下这件装备', 409);
    const amount = salvageYield(item);
    this.db.run('UPDATE equipment SET salvaged_at = ? WHERE id = ?', this.now(), equipmentId);
    this.ledger.change(actor.account_id, actor.id, 'materials', amount, id('salvage'), 'equipment_salvage');
    this.db.touch(actor.account_id);
  }

  private available(actor: Character, equipmentId: string) {
    requireCondition(actor.lifecycle !== 'ascended', 'ACTION_UNAVAILABLE', '当前角色仅可查看装备', 409);
    const item = this.db.get<GrowingEquipment>('SELECT * FROM equipment WHERE id = ? AND cultivator_id = ? AND salvaged_at IS NULL', equipmentId, actor.id);
    requireCondition(item && item.catalogue_version === pixelRules.catalogue_version, 'NOT_FOUND', '装备不存在或不属于此角色', 404);
    requireCondition(!this.db.get("SELECT id FROM market_listings WHERE equipment_id = ? AND status = 'active'", equipmentId),
      'EQUIPMENT_LISTED', '请先撤下挂单再操作装备', 409);
    return item;
  }

  private spend(actor: Character, materials: number, qi: number, reason: string) {
    const operation = id('forge');
    this.ledger.change(actor.account_id, actor.id, 'materials', -materials, operation, reason);
    this.ledger.change(actor.account_id, actor.id, 'spirit_stones', -qi, operation, reason);
  }
}
