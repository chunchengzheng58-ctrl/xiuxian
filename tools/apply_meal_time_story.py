"""Apply the approved P0 story pass without changing combat, unlocks or rewards."""
from __future__ import annotations

import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CAMPAIGN = ROOT / "data" / "adventure-campaign.v1.json"
BOSSES = ROOT / "data" / "pixel_campaign_bosses.json"


def line(speaker: str, text: str, art: str = "") -> dict[str, str]:
    value = {"speaker": speaker, "text": text}
    if art:
        value["art"] = art
    return value


CHAPTERS = {
    "origin": ("离乡前", [
        line("雷叔", "外头冷，茶喝了再走。"),
        line("母亲", "干粮分了两包。蓝绳路上吃，红绳回家吃。", "rations"),
        line("主角", "嗯。"),
    ], [
        line("雷叔", "旧灯你拿去。用不着替我擦。"),
        line("母亲", "到了，写个到字就行。"),
        line("主角", "好。"),
    ]),
    "wood": ("新绳与旧树", [
        line("阿禾", "栈道上的新绳，是阿宁系的。"),
        line("主角", "她先走了？"),
        line("阿宁留言", "不照生。别耽搁。", "map"),
    ], [
        line("阿禾", "新芽和旧树，分开种了。"),
        line("主角", "能看见水。"),
        line("阿禾", "嗯。慢慢长。"),
    ]),
    "fire": ("两份干粮", [
        line("刘婶", "双份干粮，阿宁带走一份。", "rations"),
        line("主角", "哪边？"),
        line("刘婶", "热的那边。她胃不好。"),
    ], [
        line("烬婶", "炉火小些了。"),
        line("主角", "她吃药了？"),
        line("烬婶", "嗯。苦也没放下。"),
    ]),
    "earth": ("断墙留土", [
        line("石翁", "她补了豁口。"),
        line("主角", "东墙？"),
        line("石翁", "嗯。饭凉了也没顾上。"),
    ], [
        line("石翁", "墙会再旧。"),
        line("主角", "知道。"),
        line("石翁", "吃饭要趁热。"),
    ]),
    "metal": ("风会回信", [
        line("素娘", "有封回信，落了一站。", "letter"),
        line("主角", "什么时候的？"),
        line("素娘", "很久了。你去候风亭看看。"),
    ], [
        line("素娘", "信送回去了。"),
        line("主角", "嗯。"),
        line("素娘", "这回，别等了。"),
    ]),
    "water": ("渡口灯亮", [
        line("汀兰", "她的药包挂着。", "lamp"),
        line("主角", "伤怎么样？"),
        line("汀兰", "不肯说。"),
    ], [
        line("汀兰", "船又回来了。", "boat"),
        line("主角", "嗯。"),
        line("汀兰", "沿灯走，就到村。"),
    ]),
    "side": ("先回的人", [
        line("阿宁", "我没等你。"),
        line("主角", "嗯。"),
        line("阿宁", "面呢？"),
    ], [
        line("阿宁", "地图画完了。", "map"),
        line("主角", "差一站。"),
        line("阿宁", "留着。"),
    ]),
    "echo": ("不必解释", [
        line("阿禾", "栈道上，有人先到了。"),
        line("阿宁", "听见回声了？"),
        line("主角", "没有。"),
    ], [
        line("阿宁", "先回吧。"),
        line("主角", "不去了？"),
        line("阿宁", "她认得路。"),
    ]),
    "finale": ("常生无常", [
        line("执衡", "恒常。", "chess"),
        line("阿宁", "他在等你。"),
        line("主角", "我知道。"),
    ], [
        line("执衡", "哦。", "chess"),
        line("母亲", "回来了？", "home"),
        line("主角", "嗯。", "home"),
        line("母亲", "锅里还有。", "noodles"),
    ]),
}

# Each entry: concise lobby story, prelude, resolution, entrance style, boss barks.
STAGES = {
    "b00": ("旧灯座上多了一只蜷起的雷兽；临行前，雷叔只让你先看一眼。", [
        line("雷叔", "别急着拔剑。"),
        line("主角", "铃怎么不响？"),
        line("雷叔", "灯芯沾灰了。听雷守的是旧灯，不是山路。", "lamp"),
        line("雷叔", "看清再动。"),
    ], [
        line("听雷", "……", "lamp"),
        line("雷叔", "嗯。"),
        line("母亲", "干粮拿了吗？", "rations"),
        line("主角", "拿了。"),
    ], "lamp", {"entry": "叮。", "phase": "铃还没响。", "low_hp": "灯要稳。", "defeat": "……"}),
    "b01": ("栈道新绳底下压着旧刻刀；朽梁把重量都留给了最薄的桥板。", [
        line("阿禾", "桥又响。"),
        line("主角", "绳结是新的。"),
        line("阿禾", "她系的。刻刀压在下面。", "marks"),
        line("阿禾", "朽梁拖着旧桥，走不得了。"),
    ], [
        line("朽梁", "还重。", "marks"),
        line("主角", "嗯。"),
        line("阿禾", "她留的图，能用了。", "map"),
    ], "marks", {"entry": "桥板先响。"}),
    "b02": ("百工坊的机关卡住旧绳节；涩节仍在替一尊石像继续发力。", [
        line("木匠", "涩节不肯松。"),
        line("主角", "绳节旧了。"),
        line("木匠", "他爹刻了一半。后来，机关替他使劲。", "marks"),
    ], [
        line("木匠", "一截木料。", "marks"),
        line("主角", "嗯。"),
        line("木匠", "刻刀收着。"),
    ], "marks", {"entry": "转轴咬住旧绳。"}),
    "b03": ("问春祠的老树停下新芽；树身上留着两个不同身高的刻痕。", [
        line("阿禾", "老树不发芽了。"),
        line("主角", "这里有刻痕。", "tree_marks"),
        line("阿禾", "你爹的手稳。"),
        line("主角", "嗯。", "tree_marks"),
    ], [
        line("窃荣", "还长。", "tree_marks"),
        line("阿禾", "新芽离了老树，也能活。"),
        line("阿宁留言", "我在前面。不用追。", "map"),
        line("主角", "……", "map"),
    ], "tree_marks", {"entry": "先顾新芽。", "phase": "根还连着。", "low_hp": "……", "defeat": "还长。"}),
    "b04": ("火坪边缘留着一枚药袋；烬疫把渡人的炉火聚在自己身上。", [
        line("刘婶", "火越烧越急。"),
        line("主角", "袋上有针脚。", "rations"),
        line("刘婶", "她拿了药。你娘分装了两份。"),
    ], [
        line("烬疫", "还热。", "rations"),
        line("刘婶", "药苦。"),
        line("主角", "她吃了。"),
    ], "rations", {"entry": "火口先退一步。"}),
    "b05": ("裂口旁落着一只沾灰的馒头；膨火抱得太紧，把自己也烧疼了。", [
        line("铁头", "裂口还涨。"),
        line("主角", "有馒头。", "rations"),
        line("铁头", "她落下的。"),
        line("铁头", "膨火抱得越紧，烧得越疼。"),
    ], [
        line("膨火", "还饿。", "rations"),
        line("铁头", "灰里有馒头。"),
        line("主角", "……拍一拍。"),
    ], "rations", {"entry": "别把火喂得太急。"}),
    "b06": ("炉前刻着浅浅的日期；烬婶借炉火回来的那一天，一直没走完。", [
        line("刘婶", "炉前刻着日子。", "marks"),
        line("主角", "是今天？"),
        line("刘婶", "她借炉回来，只想把这一天过完。"),
    ], [
        line("烬婶", "还赶得上。", "rations"),
        line("主角", "面要凉了。", "noodles"),
        line("刘婶", "这句……她没说。"),
    ], "rations", {"entry": "火还旺，日子却停了。"}),
    "b07": ("夯土台上的刻刀修过东墙；滞垒把旧城全抱在自己身上。", [
        line("石翁", "台基下沉。"),
        line("主角", "刻刀修过墙。", "marks"),
        line("石翁", "他补了东墙。滞垒把旧城全背上了。"),
    ], [
        line("滞垒", "还站。", "marks"),
        line("石翁", "刀旧。"),
        line("主角", "能用。"),
    ], "marks", {"entry": "先看墙脚。"}),
    "b08": ("梯田梗上留着整齐的绳结；田心不让水退，也不让自己歇。", [
        line("田婆", "田埂全鼓了。"),
        line("主角", "绳结还整齐。", "marks"),
        line("田婆", "阿宁歇过。田心不肯。"),
    ], [
        line("田心", "还长。", "marks"),
        line("田婆", "歇埂了。"),
        line("主角", "她补的那格，也空着。"),
    ], "marks", {"entry": "田要轮作，人也一样。"}),
    "b09": ("古钟里留着一件旧衣；磐首不敢让钟声停，便把自己敲聋了。", [
        line("石翁", "钟里有人声。"),
        line("主角", "像缝衣。"),
        line("石翁", "她娘年年等。后来钟替人响。", "rations"),
    ], [
        line("磐首", "还响。", "rations"),
        line("石翁", "钟架空一格。"),
        line("主角", "留着。"),
    ], "rations", {"entry": "钟声太满，先听停顿。"}),
    "b10": ("石台的刀柄缠过新布；切锋不许任何东西变钝，包括握刀的人。", [
        line("素娘", "石台太利。"),
        line("主角", "布上有针脚。", "rations"),
        line("素娘", "她娘缝的。切锋连刀柄也不许旧。"),
    ], [
        line("切锋", "还利。", "rations"),
        line("素娘", "针脚比刀口细。"),
        line("主角", "嗯。"),
    ], "rations", {"entry": "锋口亮时先让一步。"}),
    "b11": ("角楼的新绳结没有多余一圈；锢羽把最后一次起飞拉成了悬停。", [
        line("素娘", "角楼落不下。"),
        line("主角", "是她。", "marks"),
        line("素娘", "她把绳留给你。锢羽把起飞留给了昨天。"),
    ], [
        line("锢羽", "还飞。", "marks"),
        line("主角", "她会系这个。"),
        line("素娘", "你认识？"),
        line("主角", "……嗯。"),
    ], "marks", {"entry": "羽门合上前别抢。"}),
    "b12": ("候风亭压着一封寄不出去的家书；缄风只肯重复最后那一句话。", [
        line("素娘", "风把信截住了。", "letter"),
        line("主角", "哪封？", "letter"),
        line("素娘", "你爹写回家的。", "letter"),
        line("缄风", "等——", "letter"),
    ], [
        line("缄风", "……", "letter"),
        line("主角", "按时吃饭。", "letter_changed"),
        line("素娘", "信寄回去了。"),
        line("主角", "嗯。", "letter_changed"),
    ], "letter", {"entry": "等——", "phase": "风不回。", "low_hp": "……", "defeat": "……"}),
    "b13": ("灯下行囊放着伤药；蚀涟把渡船的入口咬在了自己嘴里。", [
        line("汀兰", "渡口起雾。"),
        line("主角", "药包是她的。", "lamp"),
        line("汀兰", "她去过船上。蚀涟把船困在灯下。"),
    ], [
        line("蚀涟", "还湿。", "lamp"),
        line("汀兰", "灯挑高了。"),
        line("主角", "她也能看见。"),
    ], "lamp", {"entry": "水面亮处未必安全。"}),
    "b14": ("沉水边多了一道安全绳；阿宁已经从对岸回来，伤却没有说。", [
        line("汀兰", "别下深水。"),
        line("主角", "绳上有药味。", "boat"),
        line("阿宁", "别碰水。", "boat"),
        line("主角", "你受伤了。"),
        line("阿宁", "小伤。", "boat"),
    ], [
        line("壅鳞", "还深。", "boat"),
        line("阿宁", "我回来了。"),
        line("主角", "嗯。"),
        line("阿宁", "先走。"),
    ], "boat", {"entry": "看安全绳，不看水面。"}),
    "b15": ("三碑峡水位缓了，渡口却有一条自己回来的空船。", [
        line("汀兰", "水势太稳。"),
        line("主角", "船谁划的？", "boat"),
        line("汀兰", "它自己回来的。", "boat"),
        line("壅川", "……", "boat"),
    ], [
        line("壅川", "……", "boat"),
        line("汀兰", "船上没人。"),
        line("主角", "嗯。", "boat"),
        line("汀兰", "回家吧。", "boat"),
    ], "boat", {"entry": "先让水退。", "phase": "堤还没稳。", "low_hp": "……", "defeat": "……"}),
    "b16": ("旧台边有一张被改过的地图；刹羽总想先替所有人选最短的路。", [
        line("阿宁", "我没等你。", "map"),
        line("主角", "嗯。"),
        line("阿宁", "刹羽守着旧台，不许人慢。", "map"),
    ], [
        line("刹羽", "还快。", "map"),
        line("阿宁", "她画的路，对。"),
        line("主角", "嗯。"),
        line("阿宁", "改了三次。"),
    ], "map", {"entry": "别跟着它抢第一步。"}),
    "b17": ("长夜台留着一盏给归人的灯；魇灯想把所有人都留在同一刻。", [
        line("阿宁", "灯火不灭。"),
        line("主角", "像家里。", "lamp"),
        line("阿宁", "魇灯借了他的影。", "lamp"),
        line("主角", "不是他。"),
    ], [
        line("魇灯", "还等。", "lamp"),
        line("阿宁", "灯芯去了。"),
        line("主角", "不用点着。"),
    ], "lamp", {"entry": "灯太亮时，先看影子。"}),
    "b18": ("旧栈道把熟悉的话送回来；忘机却不肯说出最后那句。", [
        line("阿宁", "栈道会学人说话。"),
        line("主角", "嗯。"),
        line("忘机", "等——", "letter"),
        line("阿宁", "别答。"),
    ], [
        line("忘机", "等——", "letter"),
        line("主角", "我先回。", "letter_changed"),
        line("阿宁", "嗯。"),
        line("主角", "她没问。"),
    ], "letter", {"entry": "听见旧话，不必回答。"}),
    "b19": ("常生台的棋还没下完；执衡把两只杯子都留在昨天。", [
        line("执衡", "恒常。", "chess"),
        line("主角", "这盘棋没下完。", "chess"),
        line("执衡", "不可变。", "chess"),
        line("阿宁", "我收灯。"),
    ], [
        line("执衡", "……哦。", "chess"),
        line("阿宁", "两杯都冷了。", "cups"),
        line("主角", "嗯。", "cups"),
        line("阿宁", "回吧。", "home"),
    ], "chess", {"entry": "不可变。", "phase": "不可缺。", "low_hp": "……", "defeat": "……哦。"}),
}

ENDING = {
    "scene_id": "ending.home",
    "title": "按时吃饭",
    "kind": "ending",
    "art": "home",
    "dialogue": [
        line("旁白", "五域的路，到这里就走完了。", "village_return"),
        line("母亲", "回来了。", "home"),
        line("主角", "嗯。", "home"),
        line("母亲", "阿宁也到了？", "home"),
        line("阿宁", "到了。", "home"),
        line("母亲", "那多拿双筷子。", "chopsticks"),
        line("旁白", "灶边有一副旧碗筷。她没有收。", "old_bowl"),
        line("母亲", "面没放葱。", "noodles"),
        line("主角", "……嗯。", "noodles"),
        line("母亲", "咸不咸？", "noodles"),
        line("主角", "不咸。", "noodles"),
        line("母亲", "那就好。", "noodles"),
        line("母亲", "锅里还有。", "noodles"),
        line("旁白", "窗外的灯，灭了一盏。院门没有关。", "door_lamp"),
    ],
}


def main() -> None:
    campaign = json.loads(CAMPAIGN.read_text(encoding="utf-8"))
    original = copy.deepcopy(campaign)
    campaign["story_title"] = "按时吃饭"
    campaign["story_version"] = "meal-time-p0-v1"
    campaign["ending_scene"] = ENDING

    assert [row["stage_id"] for row in campaign["stages"]] == [f"b{i:02d}" for i in range(20)]
    for stage in campaign["stages"]:
        stage_id = stage["stage_id"]
        story, prelude, resolution, style, barks = STAGES[stage_id]
        stage["story"] = story
        stage["world_change"] = resolution[-2]["text"] if len(resolution) > 1 else resolution[-1]["text"]
        stage["prelude"] = prelude
        stage["resolution"] = resolution
        stage["entrance"] = {"style": style, "line": barks.get("entry", ""), "motion": "emerge"}
        stage["barks"] = barks

    for chapter in campaign["chapters"]:
        title, intro, closure = CHAPTERS[chapter["id"]]
        chapter["title"] = title
        intro_node = next(row for row in chapter["nodes"] if row["kind"] == "intro")
        closure_node = next(row for row in chapter["nodes"] if row["kind"] == "closure")
        intro_node["title"] = title + "·起"
        intro_node["dialogue"] = intro
        closure_node["title"] = title + "·收"
        closure_node["dialogue"] = closure

    # Guard all gameplay and reward fields byte-for-byte at the value level.
    for before, after in zip(original["stages"], campaign["stages"], strict=True):
        for key in set(before) - {"story", "world_change"}:
            assert before[key] == after[key], (before["stage_id"], key)
    for before, after in zip(original["chapters"], campaign["chapters"], strict=True):
        for key in ("id", "region", "stage_ids", "optional", "reward"):
            assert before[key] == after[key], (before["id"], key)
        assert [row["id"] for row in before["nodes"]] == [row["id"] for row in after["nodes"]]
        assert [row["kind"] for row in before["nodes"]] == [row["kind"] for row in after["nodes"]]

    CAMPAIGN.write_text(json.dumps(campaign, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    boss_document = json.loads(BOSSES.read_text(encoding="utf-8"))
    bosses = {row["id"]: row for row in boss_document["bosses"]}
    for stage in campaign["stages"]:
        boss = bosses[stage["stage_id"]]
        spoken = stage["prelude"] + stage["resolution"]
        boss["backstory"] = stage["story"] + "".join(f"{row['speaker']}：{row['text']}" for row in spoken)
        boss["world_change"] = stage["world_change"]
    BOSSES.write_text(json.dumps(boss_document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Applied 按时吃饭 P0 to 9 chapters, 20 stages, 20 boss entries and 1 home ending.")


if __name__ == "__main__":
    main()
