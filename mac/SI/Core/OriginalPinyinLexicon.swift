/// Original, manually specified entries for SI. No third-party dictionary data is included.
/// Readings use v for ü. Order within a row is an initial preference, not a corpus frequency.
enum OriginalPinyinLexicon {
    static let entries: [PinyinLexiconEntry] = data.split(separator: "\n").flatMap { line in
        let columns = line.split(separator: "|")
        guard columns.count == 2 else { return [PinyinLexiconEntry]() }
        let reading = columns[0].split(separator: " ").map(String.init)
        return columns[1].split(separator: " ").enumerated().map { index, text in
            PinyinLexiconEntry(syllables: reading, text: String(text), score: 100 - min(index, 12))
        }
    }

    private static let data = """
    a|啊 阿
    ai|爱 矮 哎
    an|安 按 暗
    ba|把 吧 八 爸
    bai|百 白 摆
    ban|办 半 班 版
    bang|帮 棒
    bao|包 报 保 饱
    bei|被 北 杯 倍
    ben|本 笨
    bi|比 笔 必
    bian|边 变 编 便
    bie|别
    bing|并 病 冰
    bu|不 部 步
    cai|才 菜 采
    can|参 餐
    ce|测 侧 册
    cha|查 茶 差
    chang|长 常 场 唱
    che|车
    cheng|成 城 程
    chi|吃 持 池
    chu|出 处 初
    chuan|传 船 穿
    chuang|窗 创
    chun|春
    ci|次 词 此
    cong|从 聪
    cuo|错
    da|大 打 达
    dai|带 代 待
    dan|但 单 蛋
    dao|到 道 倒
    de|的 得 地
    dei|得
    deng|等 灯
    di|地 第 低 底
    dian|点 电 店
    ding|定 顶
    dong|东 动 冬 懂
    dou|都 豆
    du|读 度 独
    dui|对 队
    duo|多 朵
    e|饿 额
    en|嗯
    er|而 二 儿
    fa|发 法
    fan|反 饭 范
    fang|方 放 房
    fei|非 飞 费
    fen|分 份 粉
    feng|风 封 峰
    fu|服 复 付 父
    gai|改 该
    gan|干 感 敢
    gao|高 告 稿
    ge|个 各 歌
    gei|给
    gen|跟 根
    geng|更
    gong|工 公 共 功
    gou|够 狗 购
    guan|关 管 馆
    guang|光 广
    gui|贵 归 规
    guo|国 过 果
    ha|哈
    hai|还 海 孩
    han|汉 含 寒
    hao|好 号 浩
    he|和 喝 河 合
    hei|黑
    hen|很
    hong|红
    hou|后 候 厚
    hu|户 湖 互
    hua|话 花 化 画
    huan|换 欢 还
    hui|会 回 灰
    huo|或 活 火
    ji|机 几 及 记 级 急 鸡
    jia|家 加 假 价
    jian|见 件 间 建 简
    jiang|将 讲 江
    jiao|教 叫 交 角
    jie|接 节 解 界 街
    jin|今 进 金 近
    jing|经 京 静 景
    jiu|就 九 久 酒
    ju|句 局 居
    jue|觉 决
    kai|开
    kan|看 刊
    kao|考 靠
    ke|可 课 科 客
    kong|空 控
    kou|口
    kuai|快 块
    lai|来
    lan|蓝 兰 栏
    lao|老 劳
    le|了 乐
    lei|类 累
    leng|冷
    li|里 理 力 立 离
    lian|连 联 脸
    liang|两 量 亮
    liao|聊 料
    lin|林 临
    ling|零 另 灵
    liu|六 留 流
    long|龙 隆
    lu|路 录 陆
    lv|绿 旅 吕
    lve|略
    lun|论 轮
    ma|吗 马 妈
    mai|买 卖 麦
    man|慢 满
    mang|忙
    mao|猫 毛
    me|么
    mei|没 每 美
    men|们 门
    mi|米 密
    mian|面 免
    ming|名 明 命
    mo|模 末
    mu|目 木 母
    na|那 拿 哪
    nai|奶 耐
    nan|南 难 男
    nao|脑 闹
    ne|呢
    nei|内
    neng|能
    ni|你 呢 泥
    nian|年 念
    nin|您
    ning|宁
    niu|牛
    nv|女
    nuan|暖
    o|哦
    ou|欧 偶
    pa|怕 爬
    pai|排 拍
    pan|盘 判
    pang|旁 胖
    pao|跑 泡
    peng|朋 碰
    pi|批 皮
    pian|篇 片
    piao|票 漂
    pin|拼 品
    ping|平 评
    po|破 坡
    pu|普 铺
    qi|期 起 气 七
    qian|前 钱 千
    qiang|强 墙
    qiao|桥 巧
    qie|切 且
    qin|亲 勤
    qing|请 情 清 轻
    qiu|求 秋 球
    qu|去 区 取
    quan|全 权 圈
    que|确 却
    ran|然 染
    rang|让
    re|热
    ren|人 认 仁
    reng|仍
    ri|日
    rong|容 荣
    ru|如 入
    ruan|软
    san|三 散
    se|色
    sen|森
    shan|山 善
    shang|上 商
    shao|少 烧
    she|设 社
    shen|深 身 什
    sheng|生 声 省
    shi|是 时 事 十 试 市 师
    shou|手 收 首
    shu|书 数 输 树
    shuang|双
    shui|水 谁
    shun|顺
    shuo|说
    si|四 思 私
    song|送 松
    su|速 苏
    sui|随 岁
    suo|所 索
    ta|他 她 它
    tai|太 台
    tan|谈
    tang|堂 糖 汤
    tao|套 讨
    te|特
    ti|题 提 体
    tian|天 田
    ting|听 停 厅
    tong|同 通
    tou|头 投
    tu|图 土
    tuan|团
    tui|退 推
    wai|外
    wan|完 晚 万 玩
    wang|网 望 王
    wei|为 位 未 微
    wen|文 问 温
    wo|我 握
    wu|无 五 物 午
    xi|西 希 系 习
    xia|下 夏
    xian|先 现 县 线
    xiang|想 向 相 像 香
    xiao|小 校 笑 消
    xie|写 谢 些 鞋
    xin|新 心 信
    xing|行 型 星 兴
    xiong|兄 熊
    xiu|修 休
    xu|需 许 序
    xuan|选 宣
    xue|学 雪
    xun|寻 讯
    ya|呀 压
    yan|言 眼 研
    yang|样 养 洋
    yao|要 药 摇
    ye|也 页 夜
    yi|一 以 已 意 衣
    yin|因 音 引
    ying|应 英 影
    yong|用 永
    you|有 又 友 由
    yu|于 语 与 雨
    yuan|元 员 原 远
    yue|月 越 约
    yun|云 运
    zai|在 再 载
    zan|咱 赞
    zao|早 造
    ze|则 责
    zen|怎
    zeng|增 曾
    zhan|站 展
    zhang|张 章 长
    zhao|找 照 招
    zhe|这 着 者
    zhen|真 阵
    zheng|正 整 政
    zhi|知 只 之 直 至
    zhong|中 钟 种
    zhou|周 州
    zhu|主 住 助
    zhuan|转 专
    zhuang|装 状
    zhui|追
    zhun|准
    zhuo|桌
    zi|字 自 子
    zou|走
    zu|组 足
    zui|最 嘴
    zuo|作 做 坐
    bei jing|北京
    ce shi|测试
    cheng xu|程序
    dai ma|代码
    dian nao|电脑
    dong jing|东京
    gong zuo|工作
    hao de|好的
    kai fa|开发
    jin tian|今天
    ming tian|明天
    ni hao|你好
    ni men|你们
    peng you|朋友
    pin yin|拼音
    qing wen|请问
    ruan jian|软件
    shang hai|上海
    shen me|什么
    shi jie|世界
    shi jian|时间
    shou ji|手机
    shu ru|输入
    shu ru fa|输入法
    tian qi|天气
    wan an|晚安
    wen jian|文件
    wen ti|问题
    wo men|我们
    xi an|西安
    xi huan|喜欢
    xi tong|系统
    xian zai|现在
    xiang mu|项目
    xie xie|谢谢
    xue xi|学习
    ying wen|英文
    yu yan|语言
    zai jian|再见
    zao shang|早上
    zhe ge|这个
    zhong guo|中国
    zhong wen|中文
    zi ding yi|自定义
    zi dong|自动
    zuo tian|昨天
    bu shi|不是
    bu yao|不要
    bu neng|不能
    bu hui|不会
    bu yong|不用
    bu guo|不过
    ke yi|可以
    ke neng|可能
    ke shi|可是
    yin wei|因为
    suo yi|所以
    dan shi|但是
    ru guo|如果
    ran hou|然后
    yi jing|已经
    hai you|还有
    mei you|没有
    mei guan xi|没关系
    zen me|怎么
    wei shen me|为什么
    zen me yang|怎么样
    shen me shi hou|什么时候
    zhe yang|这样
    na yang|那样
    na ge|那个
    zhe li|这里
    na li|那里
    shi hou|时候
    wo yao|我要
    wo xiang|我想
    wo shi|我是
    wo de|我的
    ni de|你的
    ta de|他的 她的 它的
    wo men de|我们的
    ni men de|你们的
    ta men|他们 她们 它们
    hao yong|好用
    hao chi|好吃
    hao kan|好看
    hao wan|好玩
    hen hao|很好
    hen duo|很多
    yi dian|一点
    yi xie|一些
    yi ge|一个
    yi qi|一起
    yi yang|一样
    yi zhi|一直
    yi ding|一定
    yi ban|一般
    yi xia|一下
    yi hou|以后
    yi qian|以前
    yi bian|一边
    mei tian|每天
    mei ci|每次
    mei ge|每个
    da jia|大家
    zi ji|自己
    zi ran|自然
    zi shen|自身
    zhi dao|知道
    ren wei|认为
    gan jue|感觉
    xi wang|希望
    xu yao|需要
    ying gai|应该
    xiang yao|想要
    wen hua|文化
    wen zi|文字
    wen dang|文档
    wen ben|文本
    shu ju|数据
    shu ju ku|数据库
    shu ju biao|数据表
    shu ju jie gou|数据结构
    jie gou|结构
    kai shi|开始
    jie shu|结束
    wan cheng|完成
    cheng gong|成功
    shi bai|失败
    cuo wu|错误
    bang zhu|帮助
    zhi chi|支持
    bao cun|保存
    shan chu|删除
    tian jia|添加
    xiu gai|修改
    bian ji|编辑
    fu zhi|复制
    zhan tie|粘贴
    che xiao|撤销
    chong zuo|重做
    yu lan|预览
    dao ru|导入
    dao chu|导出
    sou suo|搜索
    cha zhao|查找
    dian ji|点击
    xuan ze|选择
    que ding|确定
    qu xiao|取消
    she zhi|设置
    xuan xiang|选项
    pian hao|偏好
    mo shi|模式
    zi ti|字体
    yan se|颜色
    chuang kou|窗口
    xian shi|显示
    yin cang|隐藏
    kai yuan|开源
    ban ben|版本
    geng xin|更新
    fa bu|发布
    yuan ma|源码
    wen jian ming|文件名
    lu jing|路径
    mu lu|目录
    wen jian jia|文件夹
    zhi neng|智能
    yu jing|语境
    shang xia wen|上下文
    ge xing hua|个性化
    hou xuan|候选
    hou xuan ci|候选词
    zhong ying wen|中英文
    zhong ying hun shu|中英混输
    zi fu|字符
    zi fu chuan|字符串
    han zi|汉字
    zi mu|字母
    biao dian|标点
    kong ge|空格
    shu zi|数字
    duan yu|短语
    jian cha|检查
    bao han|包含
    shang wu|上午
    xia wu|下午
    wan shang|晚上
    zhong wu|中午
    ri qi|日期
    xing qi|星期
    xing qi yi|星期一
    zhou mo|周末
    yue fen|月份
    jin nian|今年
    ming nian|明年
    qu nian|去年
    shang ban|上班
    xia ban|下班
    kai hui|开会
    hui yi|会议
    xiu xi|休息
    gong si|公司
    gong yuan|公园
    di tie|地铁
    gong jiao|公交
    ji chang|机场
    huo che|火车
    gao tie|高铁
    fei ji|飞机
    qi che|汽车
    wang zhan|网站
    wang ye|网页
    wang luo|网络
    liu lan qi|浏览器
    ying yong|应用
    ying yong cheng xu|应用程序
    zhang hao|账号
    mi ma|密码
    an quan|安全
    ben di|本地
    yin si|隐私
    yong hu|用户
    shu ru yuan|输入源
    da kai|打开
    guan bi|关闭
    qi dong|启动
    tui chu|退出
    an zhuang|安装
    xie zai|卸载
    chong qi|重启
    zhong zhi|重置
    hui fu|恢复
    bei fen|备份
    xiao shi|小时
    fen zhong|分钟
    miao zhong|秒钟
    yi hui er|一会儿
    ma shang|马上
    xian hou|先后
    qian hou|前后
    zuo you|左右
    shang mian|上面
    xia mian|下面
    li mian|里面
    wai mian|外面
    dong xi|东西
    shi qing|事情
    gong neng|功能
    fang fa|方法
    jie guo|结果
    yuan yin|原因
    ji hui|机会
    guan xi|关系
    jing yan|经验
    ji hua|计划
    mu biao|目标
    ren min|人民
    zhong guo ren|中国人
    cheng shi|城市
    sheng huo|生活
    jia ren|家人
    hai zi|孩子
    xue sheng|学生
    lao shi|老师
    tong xue|同学
    xue xiao|学校
    da xue|大学
    xie xin|写信
    du shu|读书
    kan shu|看书
    ting ge|听歌
    chi fan|吃饭
    he shui|喝水
    shui jiao|睡觉
    wan fan|晚饭
    zao fan|早饭
    wu fan|午饭
    bu ke qi|不客气
    dui bu qi|对不起
    mei wen ti|没问题
    zao shang hao|早上好
    wan shang hao|晚上好
    huan ying|欢迎
    huan ying shi yong|欢迎使用
    """
}
