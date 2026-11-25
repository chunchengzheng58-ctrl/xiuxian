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
  const traits = digest(`arena-standing-v2:${profile.id}`).match(/.{4}/g)!.slice(0, 6).map(value => Number.parseInt(value, 16) / 65_536);
  const [frequency, sessionsPerDay, experience, skill, consistency, evenMatches] = traits as [number, number, number, number, number, number];
  const play_days = 1 + Math.floor(26 * frequency ** 1.45);
  const level = Math.min(campaignConfig.progression.thresholds.length, 1 + Math.floor(play_days * (.24 + .36 * experience)));
  const matches = Math.max(1, Math.round(play_days * (1.1 + 4.1 * sessionsPerDay) + 5 * experience));
  const draws = Math.floor(matches * (.015 + .08 * evenMatches));
  const decisiveMatches = matches - draws;
  const wins = Math.round(decisiveMatches * (.24 + .20 * experience + .24 * skill));
  const losses = decisiveMatches - wins;
  const winRate = (wins + 2) / (decisiveMatches + 4);
  const rating = Math.round(635 + 10 * play_days + 2.25 * matches + 930 * (winRate - .30) + 90 * consistency);
  return { ...profile, play_days, level, rating, wins, losses, draws };
});
