import os
import re
path = './results/vcs/bp_softcore.e_bp_softcore_cfg.sim/'
sim_list = os.listdir(path)
# print(sim_list)
bht_hit_rate_list = []
for sim in sim_list:
    file_path = path + sim + "/branch_0.stats"
    f = open(file_path, 'r')
    file_content = f.read()
    hit_rate_string = re.findall('BHT hit%:          \d+', file_content)[0]
    bht_hit_rate = re.findall('\d+', hit_rate_string)[0]
    print(sim + ":" + bht_hit_rate)
    bht_hit_rate_list.append(bht_hit_rate)
    f.close()

f1=open('./branch.txt','w')
for item in bht_hit_rate_list:
	f1.write(item)
	f1.write('\n')
f1.close()

f2=open('./branch_name.txt','w')
for name in sim_list:
	f2.write(name)
	f2.write('\n')
f2.close()
