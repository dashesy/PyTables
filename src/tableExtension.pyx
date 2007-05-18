########################################################################
#
#       License: BSD
#       Created: June 17, 2005
#       Author:  Francesc Altet - faltet@carabos.com
#
#       $Id$
#
########################################################################

"""Here is where Table and Row extension types live.

Classes (type extensions):

    Table
    Row

Functions:



Misc variables:

    __version__
"""

import sys
import numpy

from tables.description import Description, Col
from tables.exceptions import HDF5ExtError
from tables.conditions import call_on_recarr
from tables.utilsExtension import \
     getNestedField, AtomFromHDF5Type, AtomToHDF5Type

# numpy functions & objects
from hdf5Extension cimport Leaf
from definitions cimport import_array, ndarray, \
     malloc, free, memcpy, strdup, strcmp, \
     PyString_AsString, Py_BEGIN_ALLOW_THREADS, Py_END_ALLOW_THREADS, \
     PyArray_GETITEM, PyArray_SETITEM, \
     H5F_ACC_RDONLY, H5P_DEFAULT, H5D_CHUNKED, H5T_DIR_DEFAULT, \
     H5F_SCOPE_LOCAL, H5F_SCOPE_GLOBAL, \
     size_t, hid_t, herr_t, hsize_t, htri_t, H5D_layout_t, H5T_class_t, \
     H5Gunlink, H5Fflush, H5Dopen, H5Dclose, H5Dread, H5Dget_type,\
     H5Dget_space, H5Dget_create_plist, H5Pget_layout, H5Pget_chunk, \
     H5Pclose, H5Sget_simple_extent_ndims, H5Sget_simple_extent_dims, \
     H5Sclose, H5Tget_size, H5Tset_size, H5Tcreate, H5Tcopy, H5Tclose, \
     H5Tget_nmembers, H5Tget_member_name, H5Tget_member_type, \
     H5Tget_native_type, H5Tget_member_value, H5Tinsert, \
     H5Tget_class, H5Tget_super, H5Tget_offset, \
     H5ATTRset_attribute_string, H5ATTRset_attribute, \
     get_len_of_range, get_order, set_order, is_complex, \
     conv_float64_timeval32


# Include conversion tables & type
include "convtypetables.pxi"


__version__ = "$Revision$"



#-----------------------------------------------------------------

# Optimized HDF5 API for PyTables
cdef extern from "H5TB-opt.h":

  herr_t H5TBOmake_table( char *table_title, hid_t loc_id, char *dset_name,
                          char *version, char *class_,
                          hid_t mem_type_id, hsize_t nrecords,
                          hsize_t chunk_size, int compress,
                          char *complib, int shuffle, int fletcher32,
                          void *data )

  herr_t H5TBOread_records( hid_t dataset_id, hid_t mem_type_id,
                            hsize_t start, hsize_t nrecords, void *data )

  herr_t H5TBOread_elements( hid_t dataset_id, hid_t mem_type_id,
                             hsize_t nrecords, void *coords, void *data )

  herr_t H5TBOappend_records( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t nrecords, hsize_t nrecords_orig,
                              void *data )

  herr_t H5TBOwrite_records ( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t start, hsize_t nrecords,
                              hsize_t step, void *data )

  herr_t H5TBOwrite_elements( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t nrecords, void *coords, void *data )

  herr_t H5TBOdelete_records( hid_t   dataset_id, hid_t   mem_type_id,
                              hsize_t ntotal_records, size_t  src_size,
                              hsize_t start, hsize_t nrecords,
                              hsize_t maxtuples )


#----------------------------------------------------------------------------

# Initialization code

# The numpy API requires this function to be called before
# using any numpy facilities in an extension module.
import_array()

#-------------------------------------------------------------


# Private functions
cdef getNestedFieldCache(recarray, fieldname, fieldcache):
#   """
#   Get the maybe nested field named `fieldname` from the `recarray`.

#   The `fieldname` may be a simple field name or a nested field name
#   with slah-separated components. It can also be an integer specifying
#   the position of the field.
#   """
  try:
    field = fieldcache[fieldname]
  except KeyError:
    # Check whether fieldname is an integer and if so, get the field
    # straight from the recarray dictionary (it can't be anywhere else)
    if isinstance(fieldname, int):
      field = recarray[fieldname]
    else:
      field = getNestedField(recarray, fieldname)
    fieldcache[fieldname] = field
  return field


cdef joinPath(object parent, object name):
  if parent == "":
    return name
  else:
    return parent + '/' + name


# Public classes

cdef class Table(Leaf):
  # instance variables
  cdef void     *wbuf
  cdef hsize_t  totalrecords


  cdef createNestedType(self, object desc, char *byteorder):
    #"""Create a nested type based on a description and return an HDF5 type."""
    cdef hid_t   tid, tid2
    cdef herr_t  ret
    cdef size_t  offset

    tid = H5Tcreate(H5T_COMPOUND, desc._v_dtype.itemsize)
    if tid < 0:
      return -1;

    offset = 0
    for k in desc._v_names:
      obj = desc._v_colObjects[k]
      if isinstance(obj, Description):
        tid2 = self.createNestedType(obj, byteorder)
      else:
        tid2 = AtomToHDF5Type(obj, byteorder)
      ret = H5Tinsert(tid, k, offset, tid2)
      offset = offset + desc._v_dtype[k].itemsize
      # Release resources
      H5Tclose(tid2)

    return tid


  def _createTable(self, char *title, char *complib, char *obversion):
    cdef int     offset
    cdef int     ret
    cdef long    buflen
    cdef hid_t   oid
    cdef void    *data
    cdef hsize_t nrecords
    cdef char    *class_
    cdef object  fieldname, name
    cdef ndarray recarr

    # Compute the complete compound datatype based on the table description
    self.disk_type_id = self.createNestedType(self.description, self.byteorder)
    self.type_id = self.createNestedType(self.description, sys.byteorder)

    # test if there is data to be saved initially
    if self._v_recarray is not None:
      self.totalrecords = self.nrows
      recarr = self._v_recarray
      data = recarr.data
    else:
      self.totalrecords = 0
      data = NULL

    class_ = PyString_AsString(self._c_classId)
    self.dataset_id = H5TBOmake_table(title, self.parent_id, self.name,
                                      obversion, class_, self.disk_type_id,
                                      self.nrows, self.chunkshape[0],
                                      self.filters.complevel, complib,
                                      self.filters.shuffle,
                                      self.filters.fletcher32,
                                      data)
    if self.dataset_id < 0:
      raise HDF5ExtError("Problems creating the table")

    # Set the conforming table attributes
    # Attach the CLASS attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "CLASS", class_)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("CLASS", self.name))
    # Attach the VERSION attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "VERSION", obversion)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("VERSION", self.name))
    # Attach the TITLE attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "TITLE", title)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("TITLE", self.name))
    # Attach the NROWS attribute
    nrecords = self.nrows
    ret = H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                              0, NULL, <char *>&nrecords )
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("NROWS", self.name))

    # Attach the FIELD_N_NAME attributes
    # We write only the first level names
    for i, name in enumerate(self.description._v_names):
      fieldname = "FIELD_%s_NAME" % i
      ret = H5ATTRset_attribute_string(self.dataset_id, fieldname, name)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         (fieldname, self.name))

    # If created in PyTables, the table is always chunked
    self._chunked = True  # Accessible from python

    # Finally, return the object identifier.
    return self.dataset_id


  cdef getNestedType(self, hid_t type_id, hid_t native_type_id,
                     object colpath, object field_byteorders):
    # """Open a nested type and return a nested dictionary as description."""
    cdef hid_t   member_type_id, native_member_type_id
    cdef hsize_t nfields, dims[1]
    cdef size_t  itemsize
    cdef int     i
    cdef char    *colname
    cdef H5T_class_t class_id
    cdef char    byteorder2[11]  # "irrelevant" fits easily here
    cdef char    *sys_byteorder
    cdef herr_t  ret
    cdef object  desc, colobj, colpath2, typeclassname, typeclass
    cdef object  byteorder

    offset = 0
    desc = {}
    # Get the number of members
    nfields = H5Tget_nmembers(type_id)
    # Iterate thru the members
    for i from 0 <= i < nfields:
      # Get the member name
      colname = H5Tget_member_name(type_id, i)
      # Get the member type
      member_type_id = H5Tget_member_type(type_id, i)
      # Get the member size
      itemsize = H5Tget_size(member_type_id)
      # Get the HDF5 class
      class_id = H5Tget_class(member_type_id)
      if class_id == H5T_COMPOUND and not is_complex(member_type_id):
        colpath2 = joinPath(colpath, colname)
        # Create the native data in-memory
        native_member_type_id = H5Tcreate(H5T_COMPOUND, itemsize)
        desc[colname] = self.getNestedType(
          member_type_id, native_member_type_id, colpath2, field_byteorders)
        desc[colname]["_v_pos"] = i  # Remember the position
      else:
        # Get the member format and the corresponding Col object
        try:
          native_member_type_id = get_native_type(member_type_id)
          atom = AtomFromHDF5Type(member_type_id)
          colobj = Col.from_atom(atom, pos=i)
        except TypeError, te:
          # Re-raise TypeError again with more info
          raise TypeError(
            ("table ``%s``, column ``%s``: %%s" % (self.name, colname))
            % te.args[0])
        desc[colname] = colobj
        # For time kinds, save the byteorder of the column
        # (useful for conversion of time datatypes later on)
        if colobj.kind == "time":
          colobj._byteorder = H5Tget_order(member_type_id)
          if colobj._byteorder == H5T_ORDER_LE:
            field_byteorders.append("little")
          else:
            field_byteorders.append("big")
        elif colobj.kind in ['int', 'uint', 'float', 'complex', 'enum']:
          # Keep track of the byteorder for this column
          ret = get_order(member_type_id, byteorder2)
          if byteorder2 in ["little", "big"]:
            field_byteorders.append(byteorder2)

      # Insert the native member
      H5Tinsert(native_type_id, colname, offset, native_member_type_id)
      # Update the offset
      offset = offset + itemsize
      # Release resources
      H5Tclose(native_member_type_id)
      H5Tclose(member_type_id)
      free(colname)

    # set the byteorder and other things (just in top level)
    if colpath == "":
      # Compute a decent byteorder for the entire table
      if len(field_byteorders) > 0:
        field_byteorders = numpy.array(field_byteorders)
        # Pyrex doesn't interpret well the extended comparison
        # operators so this: field_byteorders == "little" doesn't work
        # as expected
        if numpy.alltrue(field_byteorders.__eq__("little")):
          byteorder = "little"
        elif numpy.alltrue(field_byteorders.__eq__("big")):
          byteorder = "big"
        else:  # Yes! someone have done it!
          byteorder = "mixed"
      else:
        byteorder = "irrelevant"
      self.byteorder = byteorder
      # Correct the type size in case the memory type size is less
      # than the type in-disk (probably due to reading native HDF5
      # files written with tools that do allow introducing padding)
      # Solves bug #23
      if H5Tget_size(native_type_id) > offset:
        H5Tset_size(native_type_id, offset)

    return desc


  def _getInfo(self):
    "Get info from a table on disk."
    cdef hid_t   space_id, plist
    cdef size_t  type_size, size2
    cdef hsize_t dims[1], chunksize[1]  # enough for unidimensional tables
    cdef H5D_layout_t layout

    # Open the dataset
    self.dataset_id = H5Dopen(self.parent_id, self.name)
    # Get the datatype on disk
    self.disk_type_id = H5Dget_type(self.dataset_id)
    # Get the number of rows
    space_id = H5Dget_space(self.dataset_id)
    H5Sget_simple_extent_dims(space_id, dims, NULL)
    self.totalrecords = dims[0]
    # Make totalrecords visible in python space
    self.nrows = self.totalrecords
    # Free resources
    H5Sclose(space_id)

    # Get the layout of the datatype
    plist = H5Dget_create_plist(self.dataset_id)
    layout = H5Pget_layout(plist)
    if layout == H5D_CHUNKED:
      self._chunked = 1
      # Get the chunksize
      H5Pget_chunk(plist, 1, chunksize)
    else:
      self._chunked = 0
      chunksize[0] = 0
    H5Pclose(plist)

    # Get the type size
    type_size = H5Tget_size(self.disk_type_id)
    # Create the native data in-memory
    self.type_id = H5Tcreate(H5T_COMPOUND, type_size)
    # Fill-up the (nested) native type and description
    desc = self.getNestedType(self.disk_type_id, self.type_id, "", [])
    if desc == {}:
      raise HDF5ExtError("Problems getting desciption for table %s", self.name)

    # Return the object ID and the description
    return (self.dataset_id, desc, chunksize[0])


  cdef _convertTime64_(self, ndarray nparr, hsize_t nrecords, int sense):
#   """Converts a NumPy of Time64 elements between NumPy and HDF5 formats.

#   NumPy to HDF5 conversion is performed when 'sense' is 0.
#   Otherwise, HDF5 to NumPy conversion is performed.
#   The conversion is done in place, i.e. 'nparr' is modified.
#   """

    cdef void *t64buf
    cdef long byteoffset, bytestride, nelements

    byteoffset = 0   # NumPy objects doesn't have an offset
    bytestride = nparr.strides[0]  # supports multi-dimensional recarray
    # Compute the number of elements in the multidimensional cell
    nelements = nparr.size / len(nparr)
    t64buf = nparr.data

    conv_float64_timeval32(
      t64buf, byteoffset, bytestride, nrecords, nelements, sense)


  cdef _convertTypes(self, ndarray recarr, hsize_t nrecords, int sense):
#     """Converts columns in 'recarr' between NumPy and HDF5 formats.

#     NumPy to HDF5 conversion is performed when 'sense' is 0.
#     Otherwise, HDF5 to NumPy conversion is performed.  The conversion
#     is done in place, i.e. 'recarr' is modified.  """

    # For reading, first swap the byteorder by hand
    # (this is not currently supported by HDF5)
    if sense == 1:
      for colpathname in self.colpathnames:
        if self.coltypes[colpathname] in ["time32", "time64"]:
          colobj = self.coldescrs[colpathname]
          if hasattr(colobj, "_byteorder"):
            if colobj._byteorder != platform_byteorder:
              column = getNestedField(recarr, colpathname)
              # Do an *inplace* byteswapping
              column.byteswap(True)

    # This should be generalised to support other type conversions.
    for t64cname in self._time64colnames:
      column = getNestedField(recarr, t64cname)
      self._convertTime64_(column, nrecords, sense)


  def _open_append(self, ndarray recarr):
    self._v_recarray = <object>recarr
    # Get the pointer to the buffer data area
    self.wbuf = recarr.data


  def _append_records(self, int nrecords):
    cdef int ret

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(self._v_recarray, nrecords, 0)

    # release GIL (allow other threads to use the Python interpreter)
    Py_BEGIN_ALLOW_THREADS
    # Append the records:
    ret = H5TBOappend_records(self.dataset_id, self.type_id,
                              nrecords, self.totalrecords, self.wbuf)
    # acquire GIL (disallow other threads from using the Python interpreter)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems appending the records.")

    self.totalrecords = self.totalrecords + nrecords


  def _close_append(self):

    # Update the NROWS attribute
    if (H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                            0, NULL, <char *>&self.totalrecords) < 0):
      raise HDF5ExtError("Problems setting the NROWS attribute.")

    # Set the caches to dirty (in fact, and for the append case,
    # it should be only the caches based on limits, but anyway)
    self._dirtycache = True
    # Delete the reference to recarray as we doesn't need it anymore
    self._v_recarray = None


  def _update_records(self, hsize_t start, hsize_t stop,
                      hsize_t step, ndarray recarr):
    cdef herr_t ret
    cdef void *rbuf
    cdef hsize_t nrecords, nrows

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Compute the number of records to update
    nrecords = len(recarr)
    nrows = get_len_of_range(start, stop, step)
    if nrecords > nrows:
      nrecords = nrows

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(recarr, nrecords, 0)
    # Update the records:
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOwrite_records(self.dataset_id, self.type_id,
                             start, nrecords, step, rbuf )
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems updating the records.")

    # Set the caches to dirty
    self._dirtycache = True


  def _update_elements(self, hsize_t nrecords, ndarray elements,
                       ndarray recarr):
    cdef herr_t ret
    cdef void *rbuf, *coords

    # Get the chunk of the coords that correspond to a buffer
    coords = elements.data

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(recarr, nrecords, 0)
    # Update the records:
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOwrite_elements(self.dataset_id, self.type_id,
                              nrecords, coords, rbuf)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems updating the records.")

    # Set the caches to dirty
    self._dirtycache = True


  def _read_records(self, hsize_t start, hsize_t nrecords, ndarray recarr):
    cdef long buflen
    cdef void *rbuf
    cdef int ret

    # Correct the number of records to read, if needed
    if (start + nrecords) > self.totalrecords:
      nrecords = self.totalrecords - start

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Read the records from disk
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOread_records(self.dataset_id, self.type_id, start,
                            nrecords, rbuf)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems reading records.")

    # Convert some HDF5 types to NumPy after reading.
    self._convertTypes(recarr, nrecords, 1)

    return nrecords


  def _read_elements(self, ndarray recarr, ndarray elements):
    cdef long nrecords
    cdef void *rbuf, *rbuf2
    cdef int ret

    # Get the chunk of the coords that correspond to a buffer
    nrecords = elements.size
    # Get the pointer to the buffer data area
    rbuf = recarr.data
    # Get the pointer to the buffer coords area
    rbuf2 = elements.data

    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOread_elements(self.dataset_id, self.type_id,
                             nrecords, rbuf2, rbuf)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems reading records.")

    # Convert some HDF5 types to NumPy after reading.
    self._convertTypes(recarr, nrecords, 1)

    return nrecords


  def _remove_row(self, hsize_t nrow, hsize_t nrecords):
    cdef size_t rowsize

    # Protection against deleting too many rows
    if (nrow + nrecords > self.totalrecords):
      nrecords = self.totalrecords - nrow

    rowsize = self.rowsize
    # Using self.disk_type_id should be faster (i.e. less conversions)
    if (H5TBOdelete_records(self.dataset_id, self.disk_type_id,
                            self.totalrecords, rowsize, nrow, nrecords,
                            self.nrowsinbuf) < 0):
      raise HDF5ExtError("Problems deleting records.")
      # Return no removed records
      return 0
    self.totalrecords = self.totalrecords - nrecords
    # Attach the NROWS attribute
    H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                        0, NULL, <char *>&self.totalrecords)
    # Set the caches to dirty
    self._dirtycache = True
    # Return the number of records removed
    return nrecords



cdef class Row:
  """
  Table row iterator and field accessor.

  Instances of this class are used to fetch and set the values of individual
  table fields.  It works very much like a dictionary, where keys are the
  pathnames or positions (extended slicing is supported) of the fields in the
  associated table in a specific row.

  This class provides an *iterator interface* so that you can use the same
  ``Row`` instance to access successive table rows one after the other.  There
  are also some important methods that are useful for acessing, adding and
  modifying values in tables.

  Public instance variables
  -------------------------

  nrow
      The current row number.

      This poperty is useful for knowing which row is being dealt with in the
      middle of a loop or iterator.

  Public methods
  --------------

  append()
      Add a new row of data to the end of the dataset.
  fetch_all_fields()
      Retrieve all the fields in the current row.
  update()
      Change the data of the current row in the dataset.

  Special methods
  ---------------

  __getitem__(key)
      Get the row field specified by the ``key``.
  __setitem__(key, value)
      Set the ``key`` row field to the specified ``value``.
  """

  cdef long _row, _unsaved_nrows, _mod_nrows
  cdef hsize_t start, stop, step, nextelement, _nrow
  cdef hsize_t nrowsinbuf, nrows, nrowsread, stopindex
  cdef hsize_t startb, stopb
  cdef long long indexChunk
  cdef int     bufcounter, counter
  cdef int     exist_enum_cols
  cdef int     _riterator, _stride, _rowsize
  cdef int     whereCond, indexed
  cdef int     ro_filemode, chunked
  cdef int     _bufferinfo_done
  cdef object  dtype
  cdef object  IObuf, IObufcpy
  cdef object  wrec, wreccpy
  cdef object  wfields, rfields
  cdef object  indexValid, coords, bufcoords, index, indices
  cdef object  condfunc, condargs
  cdef object  mod_elements, colenums
  cdef object  rfieldscache, wfieldscache
  cdef object  _tableFile, _tablePath

  # The nrow() method has been converted into a property, which is handier
  property nrow:
    """
    The current row number.

    This poperty is useful for knowing which row is being dealt with in the
    middle of a loop or iterator.
    """
    def __get__(self):
      return self._nrow


  property table:
    def __get__(self):
        return self._tableFile._getNode(self._tablePath)


  def __new__(self, table):
    cdef int nfields, i
    # Location-dependent information.
    self._tableFile = table._v_file
    self._tablePath = table._v_pathname
    self._unsaved_nrows = 0
    self._mod_nrows = 0
    self._row = 0
    self._nrow = 0   # Useful in mod_append read iterators
    self._riterator = 0
    self._bufferinfo_done = 0
    # Some variables from table will be cached here
    if table._v_file.mode == 'r':
      self.ro_filemode = 1
    else:
      self.ro_filemode = 0
    self.chunked = table._chunked
    self.colenums = table._colenums
    self.exist_enum_cols = len(self.colenums)
    self.nrowsinbuf = table.nrowsinbuf
    self.dtype = table._v_dtype
    self._newBuffer(table)
    self.mod_elements = None
    self.rfieldscache = {}
    self.wfieldscache = {}


  def _iter(self, start=0, stop=0, step=1, coords=None, ncoords=0):
    """Return an iterator for traversiong the data in table."""

    self._initLoop(start, stop, step, coords, ncoords)
    return iter(self)


  def __iter__(self):
    "Iterator that traverses all the data in the Table"

    return self


  cdef _newBuffer(self, table):
#     "Create the recarrays for I/O buffering"

    self.wrec = table._v_wdflts.copy()  # The private record
    self.wreccpy = self.wrec.copy()  # A copy of the defaults
    # Build the wfields dictionary for faster access to columns
    self.wfields = {}
    for name in self.dtype.names:
      self.wfields[name] = self.wrec[name]

    # Get the read buffer for this instance (it is private, remember!)
    buff = self.IObuf = table._get_container(self.nrowsinbuf)
    # Build the rfields dictionary for faster access to columns
    # This is quite fast, as it only takes around 5 us per column
    # in my laptop (Pentium 4 @ 2 GHz).
    # F. Altet 2006-08-18
    self.rfields = {}
    for i, name in enumerate(self.dtype.names):
      self.rfields[i] = buff[name]
      self.rfields[name] = buff[name]

    # Get the stride of these buffers
    self._stride = buff.strides[0]
    # The rowsize
    self._rowsize = self.dtype.itemsize
    self.nrows = table.nrows  # This value may change


  cdef _initLoop(self, hsize_t start, hsize_t stop, hsize_t step,
                 object coords, int ncoords):
#     "Initialization for the __iter__ iterator"

    table = self.table
    self._riterator = 1   # We are inside a read iterator
    self.start = start
    self.stop = stop
    self.step = step
    self.coords = coords
    self.startb = 0
    self.nrowsread = start
    self._nrow = start - self.step
    self._row = -1  # a sentinel
    self.whereCond = 0
    self.indexed = 0

    self.nrows = table.nrows   # Update the row counter

    if table._whereCondition:
      self.whereCond = 1
      self.condfunc, self.condargs = table._whereCondition
      table._whereCondition = None
    if table._whereIndex:
      self.indexed = 1
      self.index = table.cols._g_col(table._whereIndex).index
      self.indices = self.index.indices
      self.nrowsread = 0
      self.nextelement = 0
      table._whereIndex = None

    if self.coords is not None:
      self.stopindex = coords.size
      self.nrowsread = 0
      self.nextelement = 0
    elif self.indexed:
      self.stopindex = ncoords


  def __next__(self):
#     "next() method for __iter__() that is called on each iteration"
    if self.indexed or self.coords is not None:
      return self.__next__indexed()
    elif self.whereCond:
      return self.__next__inKernel()
    else:
      return self.__next__general()


  cdef __next__indexed(self):
#     """The version of next() for indexed columns or with user coordinates"""
    cdef int recout
    cdef long long stop
    cdef long long nextelement

    while self.nextelement < self.stopindex:
      if self.nextelement >= self.nrowsread:
        # Correction for avoiding reading past self.stopindex
        if self.nrowsread+self.nrowsinbuf > self.stopindex:
          stop = self.stopindex-self.nrowsread
        else:
          stop = self.nrowsinbuf
        if self.coords is not None:
          self.bufcoords = self.coords[self.nrowsread:self.nrowsread+stop]
          nrowsread = self.bufcoords.size
        else:
          # Optmized version of getCoords in Pyrex
          self.bufcoords = self.indices._getCoords(self.index,
                                                   self.nrowsread, stop)
          nrowsread = self.bufcoords.size
          tmp = self.bufcoords
          # If a step was specified, select the strided elements first
          if tmp.size > 0 and self.step > 1:
            tmp2=(tmp-self.start) % self.step
            tmp = tmp[tmp2.__eq__(0)]
          # Now, select those indices in the range start, stop:
          if tmp.size > 0 and self.start > 0:
            # Pyrex can't use the tmp>=number notation when tmp is a numpy
            # object. Why?
            tmp = tmp[tmp.__ge__(self.start)]
          if tmp.size > 0 and self.stop < self.nrows:
            tmp = tmp[tmp.__lt__(self.stop)]
          self.bufcoords = tmp
        self._row = -1
        if self.bufcoords.size > 0:
          recout = self.table._read_elements(self.IObuf, self.bufcoords)
          if self.whereCond:
            # Evaluate the condition on this table fragment.
            self.indexValid = call_on_recarr(
              self.condfunc, self.condargs, self.rfields )
          else:
            # No residual condition, all selected rows are valid.
            self.indexValid = numpy.ones(recout, numpy.bool8)
        else:
          recout = 0
        self.nrowsread = self.nrowsread + nrowsread
        # Correction for elements that are eliminated by its
        # [start:stop:step] range
        self.nextelement = self.nextelement + nrowsread - recout
        if recout == 0:
          # no items were read, skip out
          continue
      self._row = self._row + 1
      self._nrow = self.bufcoords[self._row]
      self.nextelement = self.nextelement + 1
      # Return this row if it fullfills the residual condition
      if self.indexValid[self._row]:
        return self
    else:
      # Re-initialize the possible cuts in columns
      self.indexed = 0
      self.coords = None
      # All the elements have been read for this mode
      nextelement = self.nrows
      if nextelement >= self.nrows:
        self._finish_riterator()
      else:
        # Continue the iteration with the __next__inKernel() method
        self.start = nextelement
        self.startb = 0
        self.nrowsread = self.start
        self._nrow = self.start - self.step
        return self.__next__inKernel()


  cdef __next__inKernel(self):
#     """The version of next() in case of in-kernel conditions"""
    cdef hsize_t recout, correct
    cdef object numexpr_locals, colvar, col

    self.nextelement = self._nrow + self.step
    while self.nextelement < self.stop:
      if self.nextelement >= self.nrowsread:
        # Skip until there is interesting information
        while self.nextelement >= self.nrowsread + self.nrowsinbuf:
          self.nrowsread = self.nrowsread + self.nrowsinbuf
        # Compute the end for this iteration
        self.stopb = self.stop - self.nrowsread
        if self.stopb > self.nrowsinbuf:
          self.stopb = self.nrowsinbuf
        self._row = self.startb - self.step
        # Read a chunk
        recout = self.table._read_records(self.nextelement, self.nrowsinbuf,
                                          self.IObuf)
        self.nrowsread = self.nrowsread + recout
        self.indexChunk = -self.step

        # Evaluate the condition on this table fragment.
        self.indexValid = call_on_recarr(
          self.condfunc, self.condargs, self.rfields )

        # Is still there any interesting information in this buffer?
        if not numpy.sometrue(self.indexValid):
          # No, so take the next one
          if self.step >= self.nrowsinbuf:
            self.nextelement = self.nextelement + self.step
          else:
            self.nextelement = self.nextelement + self.nrowsinbuf
            # Correction for step size > 1
            if self.step > 1:
              correct = (self.nextelement - self.start) % self.step
              self.nextelement = self.nextelement + self.step - correct
          continue

      self._row = self._row + self.step
      self._nrow = self.nextelement
      if self._row + self.step >= self.stopb:
        # Compute the start row for the next buffer
        self.startb = 0

      self.nextelement = self._nrow + self.step
      # Return only if this value is interesting
      self.indexChunk = self.indexChunk + self.step
      if self.indexValid[self.indexChunk]:
        return self
    else:
      self._finish_riterator()


  # This is the most general __next__ version, simple, but effective
  cdef __next__general(self):
#     """The version of next() for the general cases"""
    cdef int recout

    self.nextelement = self._nrow + self.step
    while self.nextelement < self.stop:
      if self.nextelement >= self.nrowsread:
        # Skip until there is interesting information
        while self.nextelement >= self.nrowsread + self.nrowsinbuf:
          self.nrowsread = self.nrowsread + self.nrowsinbuf
        # Compute the end for this iteration
        self.stopb = self.stop - self.nrowsread
        if self.stopb > self.nrowsinbuf:
          self.stopb = self.nrowsinbuf
        self._row = self.startb - self.step
        # Read a chunk
        recout = self.table._read_records(self.nrowsread, self.nrowsinbuf,
                                          self.IObuf)
        self.nrowsread = self.nrowsread + recout

      self._row = self._row + self.step
      self._nrow = self.nextelement
      if self._row + self.step >= self.stopb:
        # Compute the start row for the next buffer
        self.startb = (self._row + self.step) % self.nrowsinbuf

      self.nextelement = self._nrow + self.step
      # Return this value
      return self
    else:
      self._finish_riterator()


  cdef _finish_riterator(self):
#     """Clean-up things after iterator has been done"""

    self.rfieldscache = {}     # empty rfields cache
    self.wfieldscache = {}     # empty wfields cache
    # Make a copy of the last read row in the private record
    # (this is useful for accessing the last row after an iterator loop)
    if self._row >= 0:
        self.wrec[:] = self.IObuf[self._row]
    self._riterator = 0        # out of iterator
    if self._mod_nrows > 0:    # Check if there is some modified row
      self._flushModRows()       # Flush any possible modified row
    raise StopIteration        # end of iteration


  def _fillCol(self, result, start, stop, step, field):
    "Read a field from a table on disk and put the result in result"
    cdef hsize_t startr, stopr, i, j, istartb, istopb
    cdef hsize_t istart, istop, istep, inrowsinbuf, inextelement, inrowsread
    cdef object fields

    # We can't reuse existing buffers in this context
    self._initLoop(start, stop, step, None, 0)
    istart, istop, istep = (self.start, self.stop, self.step)
    inrowsinbuf, inextelement, inrowsread = (self.nrowsinbuf, istart, istart)
    istartb, startr = (self.startb, 0)
    i = istart
    while i < istop:
      if (inextelement >= inrowsread + inrowsinbuf):
        inrowsread = inrowsread + inrowsinbuf
        i = i + inrowsinbuf
        continue
      # Compute the end for this iteration
      istopb = istop - inrowsread
      if istopb > inrowsinbuf:
        istopb = inrowsinbuf
      stopr = startr + ((istopb - istartb - 1) / istep) + 1
      # Read a chunk
      inrowsread = inrowsread + self.table._read_records(i, inrowsinbuf,
                                                         self.IObuf)
      # Assign the correct part to result
      fields = self.IObuf
      if field:
        fields = getNestedField(fields, field)
      result[startr:stopr] = fields[istartb:istopb:istep]

      # Compute some indexes for the next iteration
      startr = stopr
      j = istartb + ((istopb - istartb - 1) / istep) * istep
      istartb = (j+istep) % inrowsinbuf
      inextelement = inextelement + istep
      i = i + inrowsinbuf
    self._riterator = 0  # out of iterator
    return


  def append(self):
    """append(self) -> None
    Add a new row of data to the end of the dataset.

    Once you have filled the proper fields for the current row, calling this
    method actually appends the new data to the *output buffer* (which will
    eventually be dumped to disk).  If you have not set the value of a field,
    the default value of the column will be used.

    Example of use::

        row = table.row
        for i in xrange(nrows):
            row['col1'] = i-1
            row['col2'] = 'a'
            row['col3'] = -1.0
            row.append()
        table.flush()

    .. Warning:: After completion of the loop in which `Row.append()` has been
       called, it is always convenient to make a call to `Table.flush()` in
       order to avoid losing the last rows that may still remain in internal
       buffers.
    """
    cdef ndarray IObuf, wrec, wreccpy

    if self.ro_filemode:
      raise IOError("Attempt to write over a file opened in read-only mode")

    if not self.chunked:
      raise HDF5ExtError("You cannot append rows to a non-chunked table.")

    if self._riterator:
      raise NotImplementedError("You cannot append rows when in middle of a table iterator. If what you want is to update records, use Row.update() instead.")

    # Commit the private record into the write buffer
    # self.IObuf[self._unsaved_nrows] = self.wrec
    # The next is faster
    IObuf = <ndarray>self.IObuf; wrec = <ndarray>self.wrec
    memcpy(IObuf.data + self._unsaved_nrows * self._stride,
           wrec.data, self._rowsize)
    # Restore the defaults for the private record
    # self.wrec[:] = self.wreccpy
    # The next is faster
    wreccpy = <ndarray>self.wreccpy
    memcpy(wrec.data, wreccpy.data, self._rowsize)
    self._unsaved_nrows = self._unsaved_nrows + 1
    # When the buffer is full, flush it
    if self._unsaved_nrows == self.nrowsinbuf:
      self._flushBufferedRows()


  def _flushBufferedRows(self):
    if self._unsaved_nrows > 0:
      self.table._saveBufferedRows(self.IObuf, self._unsaved_nrows)
      # Reset the buffer unsaved counter
      self._unsaved_nrows = 0


  def _getUnsavedNrows(self):
    return self._unsaved_nrows


  def update(self):
    """update(self) -> None
    Change the data of the current row in the dataset.

    This method allows you to modify values in a table when you are in the
    middle of a table iterator like `Table.iterrows()` or `Table.where()`.

    Once you have filled the proper fields for the current row, calling this
    method actually changes data in the *output buffer* (which will eventually
    be dumped to disk).  If you have not set the value of a field, its
    original value will be used.

    Examples of use::

        for row in table.iterrows(step=10):
            row['col1'] = row.nrow
            row['col2'] = 'b'
            row['col3'] = 0.0
            row.update()
        table.flush()

    which modifies every tenth row in table.  Or::

        for row in table.where('col1 &gt; 3'):
            row['col1'] = row.nrow
            row['col2'] = 'b'
            row['col3'] = 0.0
            row.update()
        table.flush()

    which just updates the rows with values bigger than 3 in the first column.

    .. Warning:: After completion of the loop in which `Row.update()` has been
       called, it is always convenient to make a call to `Table.flush()` in
       order to avoid losing changed rows that may still remain in internal
       buffers.
    """
    cdef ndarray IObufcpy, IObuf

    if self.ro_filemode:
      raise IOError("Attempt to write over a file opened in read-only mode")

    if not self._riterator:
      raise NotImplementedError("You are only allowed to update rows through the Row.update() method if you are in the middle of a table iterator.")

    if self.mod_elements is None:
      # Initialize an array for keeping the modified elements
      # (just in case Row.update() would be used)
      self.mod_elements = numpy.empty(shape=self.nrowsinbuf,
                                      dtype=numpy.int64)
      # We need a different copy for self.IObuf here
      self.IObufcpy = self.IObuf.copy()

    # Add this row to the list of elements to be modified
    self.mod_elements[self._mod_nrows] = self._nrow
    # Copy the current buffer row in input to the output buffer
    # self.IObufcpy[self._mod_nrows] = self.IObuf[self._row]
    # The next is faster
    IObufcpy = <ndarray>self.IObufcpy; IObuf = <ndarray>self.IObuf
    memcpy(IObufcpy.data + self._mod_nrows * self._stride,
           IObuf.data + self._row * self._stride, self._rowsize)
    # Increase the modified buffer count by one
    self._mod_nrows = self._mod_nrows + 1
    # When the buffer is full, flush it
    if self._mod_nrows == self.nrowsinbuf:
      self._flushModRows()


  def _flushModRows(self):
    """Flush any possible modified row using Row.update()"""

    table = self.table
    # Save the records on disk
    table._update_elements(self._mod_nrows, self.mod_elements, self.IObufcpy)
    # Reset the counter of modified rows to 0
    self._mod_nrows = 0
    # Redo the indexes if needed. This could be optimized if we would
    # be able to track the modified columns.
    table._reIndex(table.colpathnames)


  # This method is twice as faster than __getattr__ because there is
  # not a lookup in the local dictionary
  def __getitem__(self, key):
    """__getitem__(self, key) -> fields
    Get the row field specified by the `key`.

    The `key` can be a string (the name of the field), an integer (the
    position of the field) or a slice (the range of field positions).  When
    `key` is a slice, the returned value is a *tuple* containing the values of
    the specified fields.

    Examples of use::

        res = [row['var3'] for row in table.where('var2 < 20')]

    which selects the ``var3`` field for all the rows that fullfill the
    condition.  Or::

        res = [row[4] for row in table if row[1] < 20]

    which selects the field in the *4th* position for all the rows that
    fullfill the condition. Or:

        res = [row[:] for row in table if row['var2'] < 20]

    which selects the all the fields (in the form of a *tuple*) for all the
    rows that fullfill the condition.  Or::

        res = [row[1::2] for row in table.iterrows(2, 3000, 3)]

    which selects all the fields in even positions (in the form of a *tuple*)
    for all the rows in the slice ``[2:3000:3]``.
    """
    cdef long offset
    cdef ndarray field
    cdef object row, fields, fieldscache

    if self._riterator:
      # If in the middle of an iterator loop, the user probably wants to
      # access the read buffer
      fieldscache = self.rfieldscache; fields = self.rfields
      offset = <long>self._row
    else:
      # We are not in an iterator loop, so the user probably wants to access
      # the write buffer
      fieldscache = self.wfieldscache; fields = self.wfields
      offset = 0

    try:
      # Check whether this object is in the cache dictionary
      field = fieldscache[key]
    except (KeyError, TypeError):
      try:
        # Try to get it from fields (str or int keys)
        field = getNestedFieldCache(fields, key, fieldscache)
      except TypeError:
        # No luck yet. Still, the key can be a slice.
        # Fetch the complete row and convert it into a tuple
        if self._riterator:
          row = self.IObuf[self._row].copy().item()
        else:
          row = self.wrec[0].copy().item()
        # Try with __getitem__()
        return row[key]

    if field.nd == 1:
      # For an scalar it is not needed a copy (immutable object)
      return PyArray_GETITEM(field, field.data + offset * self._stride)
    else:
      # Do a copy of the array, so that it can be overwritten by the user
      # whitout damaging the internal self.rfields buffer
      return field[offset].copy()


  # This is slightly faster (around 3%) than __setattr__
  def __setitem__(self, object key, object value):
    """__setitem__(self, key, value) -> None
    Set the `key` row field to the specified `value`.

    Differently from its ``__getitem__()`` counterpart, in this case `key` can
    only be a string (the name of the field).  The changes done via
    ``__setitem__()`` will not take effect on the data on disk until any of
    the `Row.append()` or `Row.update()` methods are called.

    Example of use:

        for row in table.iterrows(step=10):
            row['col1'] = row.nrow
            row['col2'] = 'b'
            row['col3'] = 0.0
            row.update()
        table.flush()

    which modifies every tenth row in the table.
    """
    cdef int ret
    cdef long offset
    cdef ndarray field
    cdef object fields, fieldscache

    if self.ro_filemode:
      raise IOError("attempt to write over a file opened in read-only mode")

    if self._riterator:
      # If in the middle of an iterator loop, or *after*, the user
      # probably wants to access the read buffer
      fieldscache = self.rfieldscache; fields = self.rfields
      offset = <long>self._row
    else:
      # We are not in an iterator loop, so the user probably wants to access
      # the write buffer
      fieldscache = self.wfieldscache; fields = self.wfields
      offset = 0

    # Check validity of enumerated value.
    if self.exist_enum_cols:
      if key in self.colenums:
        enum = self.colenums[key]
        for cenval in numpy.asarray(value).flat:
          enum(cenval)  # raises ``ValueError`` on invalid values

    # Get the field to be modified
    field = getNestedFieldCache(fields, key, fieldscache)

    # Finally, try to set it to the value
    try:
      # Optimization for scalar values. This can optimize the writes
      # between a 10% and 100%, depending on the number of columns modified
      if field.nd == 1:
        ret = PyArray_SETITEM(field, field.data + offset * self._stride, value)
        if ret < 0:
          raise TypeError
      ##### End of optimization for scalar values
      else:
        field[0] = value
    except TypeError:
      raise TypeError("invalid type (%s) for column ``%s``" % (type(value),
                                                               key))


  def fetch_all_fields(self):
    """fetch_all_fields(self) -> record
    Retrieve all the fields in the current row.

    Contrarily to ``row[:]``, this returns row data as a NumPy void scalar.
    For instance::

        [row.fetch_all_fields() for row in table.where('col1 < 3')]

    will select all the rows that fullfill the given condition as a list of
    NumPy records.
    """

    # We need to do a cast for recognizing negative row numbers!
    if <signed long long>self._nrow < 0:
      return "Warning: Row iterator has not been initialized for table:\n  %s\n %s" % \
             (self.table, \
    "You will normally want to use this method in iterator contexts.")

    # Always return a copy of the row so that new data that is written
    # in self.IObuf doesn't overwrite the original returned data.
    return self.IObuf[self._row].copy()


  def __str__(self):
    """ represent the record as an string """

    # We need to do a cast for recognizing negative row numbers!
    if <signed long long>self._nrow < 0:
      return "Warning: Row iterator has not been initialized for table:\n  %s\n %s" % \
             (self.table, \
    "You will normally want to use this object in iterator contexts.")

    outlist = []
    # Special case where Row has not been initialized yet
    if self.IObuf is None:
      return "Warning: Row iterator has not been initialized for table:\n  %s\n %s" % \
             (self.table, \
"You will normally want to use to use this object in iterator or writing contexts.")
    buf = self.IObuf;  fields = self.rfields
    for name in buf.dtype.names:
      outlist.append(`fields[name][self._row]`)
    return "(" + ", ".join(outlist) + ")"


  def __repr__(self):
    """ represent the record as an string """
    return str(self)



## Local Variables:
## mode: python
## py-indent-offset: 2
## tab-width: 2
## fill-column: 78
## End:
