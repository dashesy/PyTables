import sys
import unittest
import os
import tempfile
from Numeric import *
from tables import *
from numarray import typeDict

from test_all import verbose, allequal, cleanup
# To delete the internal attributes automagically
unittest.TestCase.tearDown = cleanup

class BasicTestCase(unittest.TestCase):
    """Basic test for all the supported typecodes present in Numeric.
    All of them are included on pytables.
    """
    endiancheck = 0

    def WriteRead(self, testArray):
        if verbose:
            print '\n', '-=' * 30
	    print "Running test for array with typecode '%s'" % \
	          testArray.typecode(),
            print "for class check:", self.title

        # Create an instance of HDF5 Table
        self.file = tempfile.mktemp(".h5")
        self.fileh = openFile(self.file, mode = "w")
        self.root = self.fileh.root
	# Create the array under root and name 'somearray'
	a = testArray
        self.fileh.createArray(self.root, 'somearray', a, "Some array")
	
        # Close the file
        self.fileh.close()
	
	# Re-open the file in read-only mode
        self.fileh = openFile(self.file, mode = "r")
        self.root = self.fileh.root
	
	# Read the saved array
	b = self.root.somearray.read()
        # For cases that read returns a python type instead of a Numeric type
        if not hasattr(b, "shape"):
            b = array(b, typecode=a.typecode())
	
	# Compare them. They should be equal.
	if not allequal(a,b, "Numeric") and verbose:
	    print "Write and read arrays differ!"
	    print "Array written:", a
	    print "Array written shape:", a.shape
	    print "Array written itemsize:", a.itemsize()
	    print "Array written type:", a.typecode()
	    print "Array read:", b
	    print "Array read shape:", b.shape
	    print "Array read itemsize:", b.itemsize()
	    print "Array read type:", b.typecode()

        # Check strictly the array equality
        assert a.shape == b.shape
        assert a.shape == self.root.somearray.shape
        if a.typecode() == "i":
            # Special expection. We have no way to distinguish between
            # "l" and "i" typecode, and we can consider them the same
            # to all practical effects
            assert (b.typecode() == "l" or b.typecode() == "i")
            assert self.root.somearray.type == typeDict["l"] or \
                   self.root.somearray.type == typeDict["i"]
        elif a.typecode() == "c":
            assert a.typecode() == b.typecode()
            assert str(self.root.somearray.type) == "CharType"
        else:
            assert a.typecode() == b.typecode()
            assert typeDict[a.typecode()] ==  self.root.somearray.type

        assert allequal(a,b, "Numeric")
        
        self.fileh.close()
        # Then, delete the file
        os.remove(self.file)
	return

    def test00_char(self):
        "Data integrity during recovery (character objects)"

        a = array(self.tupleChar,'c')
	self.WriteRead(a)
	return

    def test01_char_nc(self):
        "Data integrity during recovery (non-contiguous character objects)"
                
	a = array(self.tupleChar, 'c')
        b = a[::2]
        # Ensure that this numarray string is non-contiguous
        assert b.iscontiguous() == 0
	self.WriteRead(b)
	return

    def test02_types(self):
        "Data integrity during recovery (numerical types)"

        typecodes = ['b', '1', 's', 'i', 'l', 'f', 'd', 'F', 'D']

	for typecode in typecodes:
            a = self.tupleInt.astype(typecode)                
            self.WriteRead(a)
            
        return

    def test03_types_nc(self):
        "Data integrity during recovery (non-contiguous numerical types)"

        typecodes = ['b', '1', 's', 'i', 'l', 'f', 'd', 'F', 'D']

	for typecode in typecodes:
            a = self.tupleInt.astype(typecode)
            # This should not be tested for the rank-0 case
            if len(a.shape) == 0:
                return
            b = a[::2]
            # Ensure that this array is non-contiguous
            assert b.iscontiguous() == 0
            self.WriteRead(b)

        return


class Basic0DOneTestCase(BasicTestCase):
    # Rank-0 case
    title = "Rank-0 case 1"
    tupleInt = array(3)
    tupleChar = "3"
    
class Basic0DTwoTestCase(BasicTestCase):
    # Rank-0 case
    title = "Rank-0 case 2"
    tupleInt = array(33)
    tupleChar = "33"
    
class Basic1DOneTestCase(BasicTestCase):
    # 1D case
    title = "Rank-1 case 1"
    tupleInt = array((3,))
    tupleChar = ("a",)
    
class Basic1DTwoTestCase(BasicTestCase):
    # 1D case
    title = "Rank-1 case 2"
    tupleInt = array((3, 4))
    tupleChar = ("aaa",)
    
class Basic1DThreeTestCase(BasicTestCase):
    # 1D case
    title = "Rank-1 case 3"
    tupleInt = array((3, 4, 5))
    tupleChar = ("aaa", "bbb",)
    
class Basic2DTestCase(BasicTestCase):
    # 2D case
    title = "Rank-2 case 1"
    #tupleInt = reshape(array(arange((4)**2)), (4,)*2)
    tupleInt = ones((4,)*2)
    tupleChar = [["aa","dd"],["dd","ss"],["ss","tt"]]
    
class Basic10DTestCase(BasicTestCase):
    # 10D case
    title = "Rank-10 case 1"
    #tupleInt = reshape(array(arange((2)**10)), (2,)*10)
    tupleInt = ones((2,)*10)
    tupleChar = ones((2,)*8,'c')
    
class Basic32DTestCase(BasicTestCase):
    # 32D case (maximum)
    tupleInt = reshape(array((32,)), (1,)*32)
    # Strings seems to cause some problems with somewhat large dimensions
    # Reverting to 2D case
    tupleChar = [["aa","dd"],["dd","ss"]]
    

class UnalignedAndComplexTestCase(unittest.TestCase):
    """Basic test for all the supported typecodes present in Numeric.
    All of them are included on pytables.
    """
    endiancheck = 0

    def setUp(self):
        # Create an instance of HDF5 Table
        self.file = tempfile.mktemp(".h5")
        self.fileh = openFile(self.file, mode = "w")
        self.root = self.fileh.root

    def tearDown(self):
        self.fileh.close()

        # Then, delete the file
        os.remove(self.file)
        cleanup(self)

    def WriteRead(self, testArray):
        if verbose:
            print '\n', '-=' * 30
	    print "Running test for array with typecode '%s'" % \
	          testArray.typecode()

	# Create the array under root and name 'somearray'
	a = testArray
        self.fileh.createArray(self.root, 'somearray', a, "Some array")
	
        # Close the file
        self.fileh.close()
	
	# Re-open the file in read-only mode
        self.fileh = openFile(self.file, mode = "r")
        self.root = self.fileh.root
	
	# Read the saved array
	b = self.root.somearray.read()
	
	# Compare them. They should be equal.
	if not allequal(a,b, "Numeric") and verbose:
	    print "Write and read arrays differ!"
	    print "Array written:", a
	    print "Array written shape:", a.shape
	    print "Array written itemsize:", a.itemsize()
	    print "Array written type:", a.typecode()
	    print "Array read:", b
	    print "Array read shape:", b.shape
	    print "Array read itemsize:", b.itemsize()
	    print "Array read type:", b.typecode()

        # Check strictly the array equality
        assert a.shape == b.shape
        assert a.shape == self.root.somearray.shape
        if a.typecode() == "i":
            # Special expection. We have no way to distinguish between
            # "l" and "i" typecode, and we can consider them the same
            # to all practical effects
            assert b.typecode() == "l" or b.typecode() == "i"
            assert self.root.somearray.type == typeDict["l"] or \
                   self.root.somearray.type == typeDict["i"]
        elif a.typecode() == "c":
            assert a.typecode() == b.typecode()
            assert str(self.root.somearray.type) == "CharType"
        else:
            assert a.typecode() == b.typecode()
            assert typeDict[a.typecode()] ==  self.root.somearray.type

        assert allequal(a,b, "Numeric")

        return

    
class GroupsArrayTestCase(unittest.TestCase):
    """This test class checks combinations of arrays with groups.
    It also uses arrays ranks which ranges until 10.
    """

    def test00_iterativeGroups(self):
	
	"""Checking combinations of arrays with groups
	It also uses arrays ranks which ranges until 10.
	"""
	
	if verbose:
            print '\n', '-=' * 30
            print "Running %s.test00_iterativeGroups..." % \
	          self.__class__.__name__
		  
	# Open a new empty HDF5 file
        file = tempfile.mktemp(".h5")
        fileh = openFile(file, mode = "w")
	
	# Get the root group
	group = fileh.root
	
	# Set the type codes to test
        # "w" and "u" not tested due to some inconsistencies in charcodes
        # between numarray and Numeric
	#typecodes = ["c", 'b', '1', 's', 'w', 'i', 'u', 'l', 'f', 'd']
	typecodes = ['c', 'b', '1', 's', 'i', 'l', 'f', 'd', 'F', 'D']
	i = 1
	for typecode in typecodes:
	    # Create an array of typecode, with incrementally bigger ranges
	    a = ones((3,) * i, typecode)
	    # Save it on the HDF5 file
	    dsetname = 'array_' + typecode
	    if verbose:
		print "Creating dataset:", group._g_join(dsetname)
	    hdfarray = fileh.createArray(group, dsetname, a, "Large array")
	    # Create a new group
	    group = fileh.createGroup(group, 'group' + str(i))
	    # increment the range for next iteration
	    i += 1

	# Close the file
	fileh.close()

	# Open the previous HDF5 file in read-only mode
        fileh = openFile(file, mode = "r")
	# Get the root group
	group = fileh.root

	# Get the metadata on the previosly saved arrays
	for i in range(1,len(typecodes)):
	    # Create an array for later comparison
	    a = ones((3,) * i, typecodes[i - 1])
	    # Get the dset object hanging from group
	    dset = getattr(group, 'array_' + typecodes[i-1])
	    # Get the actual array
	    b = dset.read()
	    if not allequal(a,b, "Numeric") and verbose:
		print "Array a original. Shape: ==>", a.shape
		print "Array a original. Data: ==>", a
		print "Info from dataset:", dset._v_pathname
		print "  shape ==>", dset.shape, 
		print "  type ==> %s" % dset.type
		print "Array b read from file. Shape: ==>", b.shape,
		print ". Type ==> %s" % b.typecode()
                
            assert a.shape == b.shape
            if a.typecode() == "i":
                # Special expection. We have no way to distinguish between
                # "l" and "i" typecode, and we can consider them the same
                # to all practical effects
                assert b.typecode() == "l" or b.typecode() == "i"
            else:
                assert a.typecode() == b.typecode()
            assert allequal(a,b, "Numeric")

	    # Iterate over the next group
	    group = getattr(group, 'group' + str(i))

	# Close the file
	fileh.close()

	# Then, delete the file
        os.remove(file)

    def test01_largeRankArrays(self):
	"""Checking creation of large rank arrays (0 < rank <= 32)
	It also uses arrays ranks which ranges until maxrank.
	"""
	
	# maximum level of recursivity (deepest group level) achieved:
	# maxrank = 32 (for a effective maximum rank of 32)
        # This limit is due to HDF5 library limitations.
	# There seems to exist a bug in Numeric when dealing with
	# arrays with rank greater than 20. Also hdf5Extension has a
	# bug getting the shape of the object, that creates lots of
	# problems (segmentation faults, memory faults...)
	minrank = 1
        # maxrank = 32 # old limit (Numeric <= 22.0) 
	maxrank = 30  # This limit is set in Numeric 23.0
	
	if verbose:
            print '\n', '-=' * 30
            print "Running %s.test01_largeRankArrays..." % \
	          self.__class__.__name__
	    print "Maximum rank for tested arrays:", maxrank
	# Open a new empty HDF5 file
        #file = tempfile.mktemp(".h5")
        file = "test_array.h5"
        fileh = openFile(file, mode = "w")
	group = fileh.root
	if verbose:
	    print "Rank array writing progress: ",
	for rank in range(minrank, maxrank + 1):
	    # Create an array of integers, with incrementally bigger ranges
	    a = ones((1,) * rank, 'i')
	    if verbose:
		print "%3d," % (rank),
	    fileh.createArray(group, "array", a, "Rank: %s" % rank)
	    group = fileh.createGroup(group, 'group' + str(rank))
        # Flush the buffers
        fileh.flush()
	# Close the file
	fileh.close()
        
	# Open the previous HDF5 file in read-only mode
        fileh = openFile(file, mode = "r")
	group = fileh.root
	if verbose:
	    print
	    print "Rank array reading progress: "
	# Get the metadata on the previosly saved arrays
        for rank in range(minrank, maxrank + 1):
	    # Create an array for later comparison
	    a = ones((1,) * rank, 'i')
	    # Get the actual array
	    b = group.array.read()
	    if verbose:
		print "%3d," % (rank),
	    if not a.tolist() == b.tolist() and verbose:
		print "Info from dataset:", dset._v_pathname
		print "  Shape: ==>", dset.shape, 
		print "  typecode ==> %c" % dset.typecode
		print "Array b read from file. Shape: ==>", b.shape,
		print ". Type ==> %c" % b.typecode()
                
            assert a.shape == b.shape
            if a.typecode() == "i":
                # Special expection. We have no way to distinguish between
                # "l" and "i" typecode, and we can consider them the same
                # to all practical effects
                assert b.typecode() == "l" or b.typecode() == "i"
            else:
                assert a.typecode() == b.typecode()

            # ************** WARNING!!! *****************
            # If we compare to arrays of dimensions bigger than 20
            # we get a segmentation fault! It is most probably a bug
            # located on Numeric package.
            # I've discovered that comparing shapes and using the
            # tolist() conversion is the best to compare Numeric
            # arrays!. At least, tolist() do not crash!.
            # ************** WARNING!!! *****************
            assert a.tolist() == b.tolist()

            # Iterate over the next group
	    group = fileh.getNode(group, 'group' + str(rank))

        if verbose:
            print # This flush the stdout buffer
	# Close the file
	fileh.close()
	
	# Delete the file
        os.remove(file)
	

def suite():
    theSuite = unittest.TestSuite()
    niter = 1

    #theSuite.addTest(unittest.makeSuite(Basic1DTwoTestCase))
    for i in range(niter):
        # The scalar case test should be refined in order to work
        # specially after the solution for bug #968132
        theSuite.addTest(unittest.makeSuite(Basic0DOneTestCase))
        theSuite.addTest(unittest.makeSuite(Basic0DTwoTestCase))
        theSuite.addTest(unittest.makeSuite(Basic1DOneTestCase))
        theSuite.addTest(unittest.makeSuite(Basic1DTwoTestCase))
        theSuite.addTest(unittest.makeSuite(Basic1DThreeTestCase))
        theSuite.addTest(unittest.makeSuite(Basic2DTestCase))
        theSuite.addTest(unittest.makeSuite(Basic10DTestCase))
        # The 32 dimensions case is tested on GroupsArray
        #theSuite.addTest(unittest.makeSuite(Basic32DTestCase))
        theSuite.addTest(unittest.makeSuite(GroupsArrayTestCase))
        theSuite.addTest(unittest.makeSuite(UnalignedAndComplexTestCase))

    return theSuite


if __name__ == '__main__':
    unittest.main( defaultTest='suite' )
