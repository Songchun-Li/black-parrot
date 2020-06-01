import pandas as pd
f1 = open('./branch.txt', 'r')
f1_contents = f1.readlines()
modified_data_list = []
for data in f1_contents:
    data = data.strip('\n')
    modified_data_list.append(data)
f1.close()

f1_name = open('./branch_name.txt', 'r')
f1_name_contents = f1_name.readlines()
modified_name_list = []
for name in f1_name_contents:
    name = name.strip('\n')
    modified_name_list.append(name)
f1_name.close()

f2 = open('./branch_baseline.txt', 'r')
f2_contents = f2.readlines()
baseline_data_list = []
for data in f2_contents:
    data = data.strip('\n')
    baseline_data_list.append(data)
f2.close()

f2_name = open('./branch_name_baseline.txt', 'r')
f2_name_contents = f2_name.readlines()
baseline_name_list = []
for name in f2_name_contents:
    name = name.strip('\n')
    baseline_name_list.append(name)
f2_name.close()


df_list = {"modified_sim": modified_name_list,
           "modified_data": modified_data_list,
           "baseline_sim": baseline_name_list,
           "baseline_data":baseline_data_list}
df=pd.DataFrame(df_list)
df.to_csv('./branch_compare.csv', index = False)
