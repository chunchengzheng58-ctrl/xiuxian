import { digest } from '../core.js';
import { campaignConfig } from './character-progression.js';

type PracticeIdentity = { id: string; avatar: 'male' | 'female'; style: number };

// Retain these eight IDs and their gameplay styles for existing match records.
const previousRoster: PracticeIdentity[] = [
  { id: '青岫47', avatar: 'male', style: 0 },
  { id: 'LingZhou08', avatar: 'female', style: 1 },
  { id: '停云_17', avatar: 'female', style: 2 },
  { id: '栖鹤313', avatar: 'male', style: 3 },
  { id: '海棠夜雨', avatar: 'female', style: 0 },
  { id: 'QiuBai26', avatar: 'male', style: 1 },
  { id: '晚钟92', avatar: 'male', style: 2 },
  { id: '归舟_406', avatar: 'female', style: 3 },
];

const nicknames = [
  '林深见鹿', '柚子茶', '风起南山', '江上月', '阿沐不困', '沈星河', '言小七', '一盏春雨', '白衣过客', '山海渡',
  '小周练剑', '江舟有信', '听潮_3', '南窗的猫', '晚风还在', 'PeachLin', '叁两糖', '青苔路', '闲云十三', '小岛来信',
  '木白不白', '瑾言', '星落东篱', '禾页', 'WenNing_2', '带伞的雨', '闻舟77', '烬灯', '鸢尾的信', '懒得御剑',
  '林屿17', '晴野', '长安小客', '椰子拿铁', '陆叙', '三月初十', '弦上春', 'FarAsh', '蜗牛爬山', '余烬秋',
  '小池不语', '乌衣蓝', '九野', '一枝海风', '岑青', '误入长街', 'Mori_x', '橘子九号', '半格电量', '春山鹧鸪',
  '北洛12', '江边石子', '茶水不加糖', '芥子落尘', '半寸光', '南巷信使', 'NuoNuo7', '沈砚', '白桃半熟', '没带药',
  '楼下有风', '顾言31', '雨落松坡', '木桥呀', 'QinYu_6', '一尾青鱼', '会迟到的云', '梧桐吹雪', '迟棠', '渡口灯',
  '冻柠茶加冰', '落日和猫', '行止_28', '石榴皮', '醒来听海', '阿岚73', '错过晚班船', 'BeiMu', '山里来客', '梨落一白',
  '听枝', '禾木_5', '灯下翻书', '云上捡星', '鹤影入林', '重青', 'ShiYan9', '画窗', '不见山', '一小颗栗子',
  '远山慢', '旧巷拾风',
];

const stableSeed = (id: string) => Number.parseInt(digest(`arena-profile-v1:${id}`).slice(0, 8), 16);

const additional = nicknames.map((id): PracticeIdentity => {
  const seed = stableSeed(id);
  return { id, avatar: (seed & 4) === 0 ? 'male' : 'female', style: seed & 3 };
});

export const practiceRoster = [...previousRoster, ...additional].map(profile => {
  const seed = stableSeed(profile.id);
  const play_days = 2 + seed % 96;
  const level = Math.min(campaignConfig.progression.thresholds.length, Math.max(1, Math.floor(Math.sqrt(play_days)) + (seed >>> 8) % 5 - 1));
  const rating = 820 + (seed >>> 7) % 189;
  const matches = 5 + Math.floor(play_days * 0.6) + (seed >>> 17) % 9;
  const draws = (seed >>> 24) % 4;
  const decisiveMatches = matches - draws;
  const wins = Math.round(decisiveMatches * (0.30 + (rating - 820) / 800));
  const losses = decisiveMatches - wins;
  return { ...profile, play_days, level, rating, wins, losses, draws };
});
