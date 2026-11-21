// pbr custom user file: China IPv4 list -> wan user destination set.
// 2026-11-21, Xiaomi AX6000 split tunnel (China direct, foreign via warp).
// Mirrors the shipped pbr.user.aws.uc / pbr.user.netflix.uc pattern:
// on every pbr start/reload, download the China CIDR list and add it
// to the wan interface's nft user set (pbr_wan_4_dst_ip_user). pbr
// emits that set's match rule ahead of the policy rules, so China
// destinations go via wan while the catch-all policy sends the rest
// via warp. If the download fails (offline at boot, list moved), log
// and return without breaking pbr: traffic then follows the warp
// policy, and with warp disabled it falls back to the default route.
// Requires pbr 1.2.x (ucode implementation). On pbr 1.1.x this file
// is ignored as incompatible and the split does not apply (no crash).
return function(api) {
	if (!api.compat || api.compat < 29) return;
	let set4 = api.nftset('wan', '4');
	if (!set4) return;
	let url = 'https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt';
	let body = api.download(url);
	if (!body) {
		print('pbr.user.china: download failed for ' + url + ', China set left empty');
		return;
	}
	let lines = body.split('\n');
	let chunk = [];
	let count = 0;
	let flush = function() {
		if (length(chunk) == 0) return;
		api.nft4('add element ' + api.table + ' ' + set4 + ' { ' + join(', ', chunk) + ' }');
		chunk = [];
	};
	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);
		if (!line || substr(line, 0, 1) == '#') continue;
		push(chunk, line);
		count++;
		if (length(chunk) >= 200) flush();
	}
	flush();
	print('pbr.user.china: added ' + count + ' China prefixes to ' + set4);
};
