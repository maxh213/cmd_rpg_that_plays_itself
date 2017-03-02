import random, string

MAP_SIZE = 10
CHARACTER_AMOUNT = 5

class Character:
	def __init__(self, name, level, x, y):
		self.name = name
		self.level = level
		self.x = x
		self.y = y
		self.exp = 0

	def get_location(self):
		return self.x, self.y

	def get_name(self):
		return self.name

	def get_level(self):
		return self.level

	def get_exp_to_level(self):
		return self.level * 2

	def gain_exp(self, exp):
		#this erases extra exp on level up
		self.exp += exp
		if self.exp > get_exp_to_level():
			self.level += 1
			self.exp = 0
	
	def get_survive_value(self):
		return random.randint(0, self.level)

def get_random_name(length):
	return ''.join(random.choice(string.ascii_letters + string.digits) for i in range(length))

def print_map(map):
	for i in range(len(map)):
                print(map[i])

def init_map():
	map = []
	for i in range(MAP_SIZE):
		map.append([])
		for j in range(MAP_SIZE):
			map[i].append([])
	return map

def init_character_list():
	character_list = []
	for i in range(CHARACTER_AMOUNT):
		character_list.append(Character(get_random_name(3), 1, random.randint(0, MAP_SIZE-1), random.randint(0, MAP_SIZE-1)))
	return character_list

def populate_map(map, characters):
	for i in range(len(characters)):
		map[characters[i].x][characters[i].y].append(characters[i].name)
	return map
	

def main():
	character_list = init_character_list() 
	map = populate_map(init_map(), character_list)
	print_map(map)

if __name__ == '__main__':
	main()
