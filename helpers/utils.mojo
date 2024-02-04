from tensor import Tensor, TensorShape
from algorithm import parallelize, vectorize, vectorize_unroll
from algorithm import Static2DTileUnitFunc as Tile2DFunc
from random import rand, random_float64
from sys.info import simdwidthof
from memory import memset_zero
from sys.intrinsics import strided_load
from math import trunc, mod

alias float_base = Float32
alias float_dtype = DType.float32
alias tensor_type = Tensor[float_dtype]
alias simd_width: Int = simdwidthof[float_dtype]()

# Perform 2D tiling on the iteration space defined by end_x and end_y.
fn tile_2d[tiled_fn: Tile2DFunc, stride_x: Int, stride_y: Int](end_x: Int, end_y: Int):
    # Note: this assumes that ends are multiples of the tiles.
    for y in range(0, end_y, stride_y):
        for x in range(0, end_x, stride_x):
            tiled_fn[stride_x, stride_y](x, y)

fn Softmax(inout matrix: Matrix[float_dtype], dim:Int = 0) -> Matrix[float_dtype]:
    
    var exp_matrix = matrix.exp()

    if dim == 0:
        @parameter
        fn channel_softmax(channel: Int):
            let channel_sum = exp_matrix[channel, :, :].sum()
            var channel_div = exp_matrix[channel, :, :] / channel_sum
            exp_matrix.set_items(channel, slice(0, matrix.dim1), slice(0, matrix.dim2), channel_div)
        parallelize[channel_softmax](matrix.dim0, matrix.dim0)
        return exp_matrix
    elif dim == 1:
        @parameter
        fn row_softmax_channel(channel: Int):
            @parameter
            fn row_softmax(row: Int):
                let row_sum = exp_matrix[channel, row, :].sum()
                var row_div = exp_matrix[channel, row, :] / row_sum
                exp_matrix.set_items(channel, row, slice(0, matrix.dim2), row_div)
            parallelize[row_softmax](matrix.dim1, matrix.dim1)
        parallelize[row_softmax_channel](matrix.dim0, matrix.dim0)
        return exp_matrix

    elif dim == 2:
        @parameter
        fn column_softmax_channel(channel: Int):
            @parameter
            fn column_softmax(column: Int):
                let col_sum = exp_matrix[channel, :, column].sum()
                var col_div = exp_matrix[channel, :, column] / col_sum
                exp_matrix.set_items(channel, slice(0, matrix.dim1), column, col_div)
            parallelize[column_softmax](matrix.dim2, matrix.dim2)
        parallelize[column_softmax_channel](matrix.dim0, matrix.dim0)
        return exp_matrix
    else:
        print("Invalid dimension for softmax. Returning null matrix")
        return Matrix[float_dtype](0, 0, 0)

struct Matrix_Array[dtype: DType]:
    var _data: DTypePointer[dtype]
    var matrix_shape: Tuple[Int, Int, Int]
    var matrix_size: Int
    var num_elements: Int

    fn __init__(inout self, num_elements: Int, matrix_shape: Tuple[Int, Int, Int]):
        self.matrix_shape = matrix_shape
        self.matrix_size = Tuple.get[0, Int](matrix_shape) * Tuple.get[1, Int](matrix_shape) * Tuple.get[2, Int](matrix_shape)
        self.num_elements = num_elements
        self._data = DTypePointer[dtype].alloc(self.matrix_size * num_elements)

    fn __copyinit__(inout self, other: Self):
        self._data = other._data
        self.matrix_shape = other.matrix_shape
        self.matrix_size = other.matrix_size
        self.num_elements = other.num_elements

    fn __setitem__(inout self, owned index: Int, new_el: Matrix[dtype]):
        let memory_index = index * self.matrix_size

        @parameter
        fn set_matrix(i : Int):
            self._data[memory_index + i] = new_el._data[i]

        parallelize[set_matrix](self.matrix_size, self.matrix_size)

    fn __getitem__(self, owned index: Int) -> Matrix[dtype]:
        let memory_index = index * self.matrix_size
        let dim0 = Tuple.get[0, Int](self.matrix_shape)
        let dim1 = Tuple.get[1, Int](self.matrix_shape)
        let dim2 = Tuple.get[2, Int](self.matrix_shape)
        var new_matrix = Matrix[dtype](dim0, dim1, dim2)

        @parameter
        fn get_matrix(i : Int):
            new_matrix._data[i] = self._data[memory_index + i]

        parallelize[get_matrix](self.matrix_size, self.matrix_size)

        return new_matrix

    fn print(self):
        for i in range(self.num_elements):
            print("Matrix", i)
            self[i].print()


# Check out https://github.com/modularml/mojo/blob/main/examples/blogs-videos/mojo-matrix-slice.ipynb
struct Matrix[dtype: DType]:
    var dim0: Int
    var dim1: Int
    var dim2: Int
    var _data: DTypePointer[dtype]

    fn __init__(inout self, *dims: Int):
        if dims[0] < 0 or dims[1] < 0 or dims[2] < 0:
            self.dim0 = 0
            self.dim1 = 0
            self.dim2 = 0
        self.dim0 = dims[0]
        self.dim1 = dims[1]
        self.dim2 = dims[2]
        self._data = DTypePointer[dtype].alloc(dims[0] * dims[1] * dims[2])
        rand(self._data, dims[0] * dims[1] * dims[2])

    fn init_weights(inout self, lower_bound: float_base, upper_bound:float_base):
        let low_bound = lower_bound.cast[DType.float64]()
        let up_bound = upper_bound.cast[DType.float64]()

        @parameter
        fn init_weights_fn[width: Int](index: Int) -> None:
            let weight_val = random_float64(low_bound, up_bound)
            let weight_simd = SIMD[DType.float64, width].splat(weight_val)
            let weight_simd_dtype = weight_simd.cast[dtype]()
            self._data.simd_store[width](index, weight_simd_dtype)

        vectorize[1, init_weights_fn](self.size().to_int())

    fn __copyinit__(inout self, other: Self):
        self._data = other._data
        self.dim0 = other.dim0
        self.dim1 = other.dim1
        self.dim2 = other.dim2

    fn __adjust_slice__(self, inout span: slice, dim: Int) -> slice:
        if span.start >= dim:
            span.start = dim - 1
        elif span.start < 0:
            span.start += dim
            if span.start < 0:
                span.start = 0
        if not span._has_end():
            span.end = dim
        elif span.end < 0:
            span.end += dim + 1
            if span.end < 0:
                span.end = 0
        elif span.end > dim:
            span.end = dim
        if span.end < span.start:
            span.start = 0
            span.end = 0
        return span

    fn __adjust_index(self, inout index: Int, dim: Int) -> Int:
        if index < 0:
            index += dim
            if index < 0:
                index = 0
        if index >= dim:
            index = dim - 1
        return index

    fn load[simd_width: Int](self, z: Int, y: Int, x: Int) -> SIMD[dtype, simd_width]:
        let index = z * self.dim2 * self.dim1 + y * self.dim2 + x
        return self._data.simd_load[simd_width](index)

    fn store[simd_width: Int](self, z:Int, y: Int, x: Int, val: SIMD[dtype, simd_width]):
        let index = z * self.dim2 * self.dim1 + y * self.dim2 + x
        return self._data.simd_store[simd_width](index, val)

    fn __setitem__(self, owned z: Int, owned x: Int, owned y: Int, val: SIMD[dtype, 1]):
        z = self.__adjust_index(z, self.dim0)
        x = self.__adjust_index(x, self.dim1)
        y = self.__adjust_index(y, self.dim2)
        let val_simd = SIMD[dtype, 1].splat(val.cast[dtype]())
        self.store[1](z, x, y, val_simd)

    fn set_items(
        inout self, owned channel: Int, owned row: Int, col: Int, val: float_base
    ):
        self.set_items(
            slice(channel, channel + 1), slice(row, row + 1), slice(col, col + 1), val
        )

    fn set_items(
        inout self,
        owned channel_slice: slice,
        owned row_slice: slice,
        col: Int,
        val: float_base,
    ):
        self.set_items(channel_slice, row_slice, slice(col, col + 1), val)

    fn set_items(
        inout self,
        owned channel_slice: slice,
        row: Int,
        owned col_slice: slice,
        val: float_base,
    ):
        self.set_items(channel_slice, slice(row, row + 1), col_slice, val)

    fn set_items(
        inout self, owned channel_slice: slice, row: Int, col: Int, val: float_base
    ):
        self.set_items(channel_slice, slice(row, row + 1), slice(col, col + 1), val)

    fn set_items(
        inout self,
        channel: Int,
        owned row_slice: slice,
        owned col_slice: slice,
        val: float_base,
    ):
        self.set_items(slice(channel, channel + 1), row_slice, col_slice, val)

    fn set_items(
        inout self, channel: Int, owned row_slice: slice, col: Int, val: float_base
    ):
        self.set_items(slice(channel, channel + 1), row_slice, slice(col, col + 1), val)

    fn set_items(
        inout self, channel: Int, row: Int, owned col_slice: slice, val: float_base
    ):
        self.set_items(slice(channel, channel + 1), slice(row, row + 1), col_slice, val)

    # Example usage: b.set_items(1,1,slice(0,3), 7)
    fn set_items(
        inout self,
        owned channel_slice: slice,
        owned row_slice: slice,
        owned col_slice: slice,
        val: float_base,
    ):
        channel_slice = self.__adjust_slice__(channel_slice, self.dim0)
        row_slice = self.__adjust_slice__(row_slice, self.dim1)
        col_slice = self.__adjust_slice__(col_slice, self.dim2)
        let val_simd = SIMD[dtype, 1].splat(val.cast[dtype]())

        @parameter
        fn slice_channels_fn(channel_idx: Int):
            @parameter
            fn slice_row_fn(row_idx: Int):
                @parameter
                fn slice_col_fn[simd_width: Int](col_idx: Int) -> None:

                    self.store[simd_width](
                        channel_slice[channel_idx],
                        row_slice[row_idx],
                        col_slice[0] + (col_idx),
                        val_simd,
                    )

                vectorize_unroll[simd_width, simd_width, slice_col_fn](
                    col_slice.__len__()
                )

            parallelize[slice_row_fn](row_slice.__len__(), row_slice.__len__())

        parallelize[slice_channels_fn](channel_slice.__len__(), channel_slice.__len__())

    fn set_items(
        inout self,
        owned channel: Int,
        owned row: Int,
        col: Int,
        inout vals: Self,
    ) :
        self.set_items(
            slice(channel, channel + 1), slice(row, row + 1), slice(col, col + 1), vals
        )

    fn set_items(
        inout self,
        owned channel_slice: slice,
        owned row_slice: slice,
        col: Int,
        inout vals: Self,
    ) :
        self.set_items(channel_slice, row_slice, slice(col, col + 1), vals)

    fn set_items(
        inout self,
        owned channel_slice: slice,
        row: Int,
        owned col_slice: slice,
        inout vals: Self,
    ) :
        self.set_items(channel_slice, slice(row, row + 1), col_slice, vals)

    fn set_items(
        inout self,
        owned channel_slice: slice,
        row: Int,
        col: Int,
        inout vals: Self,
    ) :
        self.set_items(channel_slice, slice(row, row + 1), slice(col, col + 1), vals)

    fn set_items(
        inout self,
        channel: Int,
        owned row_slice: slice,
        owned col_slice: slice,
        inout vals: Self,
    ) :
        self.set_items(slice(channel, channel + 1), row_slice, col_slice, vals)

    fn set_items(
        inout self,
        channel: Int,
        owned row_slice: slice,
        col: Int,
        inout vals: Self,
    ) :
        self.set_items(
            slice(channel, channel + 1), row_slice, slice(col, col + 1), vals
        )

    fn set_items(
        inout self,
        channel: Int,
        row: Int,
        owned col_slice: slice,
        inout vals: Self,
    ) :
        self.set_items(
            slice(channel, channel + 1), slice(row, row + 1), col_slice, vals
        )

    # Usage: b.set_items(slice(0, 3), slice(0, 3), slice(0, 3), c)
    fn set_items(
        inout self,
        owned channel_slice: slice,
        owned row_slice: slice,
        owned col_slice: slice,
        inout vals: Self,
    ):
        channel_slice = self.__adjust_slice__(channel_slice, self.dim0)
        row_slice = self.__adjust_slice__(row_slice, self.dim1)
        col_slice = self.__adjust_slice__(col_slice, self.dim2)

        if (
            channel_slice.__len__() * row_slice.__len__() * col_slice.__len__()
            != vals.dim0 * vals.dim1 * vals.dim2
        ):
            return

        vals = vals.reshape(
            channel_slice.__len__(), row_slice.__len__(), col_slice.__len__()
        )

        @parameter
        fn slice_channels_fn(channel_idx: Int):
            @parameter
            fn slice_rows_fn(row_idx: Int):
                @parameter
                fn slice_cols_fn[simd_width: Int](idx: Int) -> None:
                    let vals_idx = vals._data.offset(
                        channel_idx * row_slice.__len__() * col_slice.__len__()
                        + row_idx * col_slice.__len__()
                        + idx
                    )
                    let loaded_val = strided_load[dtype, simd_width](
                        vals_idx, col_slice.step
                    )

                    self.store[simd_width](channel_slice[channel_idx], row_slice[row_idx], col_slice[0] + (idx * col_slice.step), loaded_val)

                vectorize_unroll[simd_width, simd_width, slice_cols_fn](
                    col_slice.__len__()
                )

            parallelize[slice_rows_fn](row_slice.__len__(), row_slice.__len__())

        parallelize[slice_channels_fn](channel_slice.__len__(), channel_slice.__len__())

    # Usage: b.set_items(1,1,1), c)
    fn slice_items(inout self, inout vals: Self) :
        self.set_items(
            slice(0, self.dim0), slice(0, self.dim1), slice(0, self.dim2), vals
        )

    fn __getitem__(self, owned z: Int, owned x: Int, owned y: Int) -> SIMD[dtype, 1]:
        z = self.__adjust_index(z, self.dim0)
        x = self.__adjust_index(x, self.dim1)
        y = self.__adjust_index(y, self.dim2)
        let channel_adjustment = z * (self.dim1 * self.dim2)
        let row_adjustment = x * self.dim2
        return self._data.simd_load[1](channel_adjustment + row_adjustment + y)

    fn __getitem__(
        self, owned channel_slice: slice, owned row_slice: slice, col: Int
    ) -> Self:
        return self.__getitem__(channel_slice, row_slice, slice(col, col + 1))

    fn __getitem__(
        self, owned channel_slice: slice, row: Int, owned col_slice: slice
    ) -> Self:
        return self.__getitem__(channel_slice, slice(row, row + 1), col_slice)

    fn __getitem__(self, owned channel_slice: slice, row: Int, col: Int) -> Self:
        return self.__getitem__(channel_slice, slice(row, row + 1), slice(col, col + 1))

    fn __getitem__(
        self, channel: Int, owned row_slice: slice, owned col_slice: slice
    ) -> Self:
        return self.__getitem__(slice(channel, channel + 1), row_slice, col_slice)

    fn __getitem__(self, channel: Int, owned row_slice: slice, col: Int) -> Self:
        return self.__getitem__(
            slice(channel, channel + 1), row_slice, slice(col, col + 1)
        )

    fn __getitem__(self, channel: Int, row: Int, owned col_slice: slice) -> Self:
        return self.__getitem__(
            slice(channel, channel + 1), slice(row, row + 1), col_slice
        )

    # Usage: a[:, 2:4, 7:]
    fn __getitem__(
        self, owned channel_slice: slice, owned row_slice: slice, owned col_slice: slice
    ) -> Self:
        channel_slice = self.__adjust_slice__(channel_slice, self.dim0)
        row_slice = self.__adjust_slice__(row_slice, self.dim1)
        col_slice = self.__adjust_slice__(col_slice, self.dim2)

        var sliced_mat = Self(
            channel_slice.__len__(), row_slice.__len__(), col_slice.__len__()
        )

        @parameter
        fn slice_channels_fn(channel_idx: Int):
            let channel_ptr = self._data.offset(
                channel_slice[channel_idx] * self.dim1 * self.dim2
            )

            @parameter
            fn slice_rows_fn(row_idx: Int):
                let row_ptr = channel_ptr.offset(
                    row_slice[row_idx] * self.dim2 + col_slice[0]
                )

                @parameter
                fn slice_cols_fn[simd_width: Int](idx: Int):
                    let mat_idx = channel_idx * row_slice.__len__() * col_slice.__len__() + row_idx * col_slice.__len__() + idx

                    let idx_pointer = row_ptr.offset(idx * col_slice.step * simd_width)
                    let loaded_val = strided_load[dtype, simd_width](
                        idx_pointer, col_slice.step
                    )
                    sliced_mat._data.simd_store[simd_width](mat_idx, loaded_val)

                vectorize_unroll[simd_width, simd_width, slice_cols_fn](
                    col_slice.__len__()
                )

            parallelize[slice_rows_fn](row_slice.__len__(), row_slice.__len__())

        parallelize[slice_channels_fn](channel_slice.__len__(), channel_slice.__len__())

        return sliced_mat

    fn size(self) -> float_base:
        return self.dim0 * self.dim1 * self.dim2

    fn print_dims(self) -> None:
        print(
            "Matrix:",
            self.dim0,
            "x",
            self.dim1,
            "x",
            self.dim2,
            ",",
            "DType:",
            dtype.__str__(),
        )

    fn reshape(inout self, dim0: Int, dim1: Int, dim2: Int)  -> Self:
        if dim0 * dim1 * dim2 != self.dim0 * self.dim1 * self.dim2:
            print("Invalid reshape dimensions that do not match the input size. Returning null matrix")
            return Self(0, 0, 0)

        if dim0 == self.dim0 and dim1 == self.dim1 and dim2 == self.dim2:
            return self

        if dim0 < 0 or dim1 < 0 or dim2 < 0:
            print("Invalid negative reshape dimensions. Returning null matrix")
            return Self(0, 0, 0)

        self.dim0 = dim0
        self.dim1 = dim1
        self.dim2 = dim2

        return self

    fn exp(self)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn exp_fn[simd_width: Int](index: Int) -> None:
            new_matrix._data.simd_store[simd_width](
                index, math.exp(self._data.simd_load[simd_width](index))
            )

        vectorize[simd_width, exp_fn](new_matrix_size)

        return new_matrix

    fn sqrt(self)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn sqrt_fn[simd_width: Int](index: Int) -> None:
            new_matrix._data.simd_store[simd_width](
                index, math.sqrt(self._data.simd_load[simd_width](index))
            )

        vectorize[simd_width, sqrt_fn](new_matrix_size)

        return new_matrix

    fn __mul__(self, y: float_base)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn mul_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__mul__(y_simd)
            new_matrix._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, mul_fn](new_matrix_size)

        return new_matrix

    fn __imul__(self, y: float_base) -> None:
        @parameter
        fn mul_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__mul__(y_simd)
            self._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, mul_fn](self.size().to_int())

    fn __pow__(self, y: float_base)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn pow_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__pow__(y_simd)
            new_matrix._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, pow_fn](new_matrix_size)

        return new_matrix

    fn __ipow__(self, y: float_base) -> None:
        @parameter
        fn pow_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__pow__(y_simd)
            self._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, pow_fn](self.size().to_int())

    fn __add__(self, y: float_base)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn add_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__add__(y_simd)
            new_matrix._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, add_fn](new_matrix_size)

        return new_matrix

    fn __add__(self, other: Self)  -> Self:
        if self.dim0 != other.dim0 or self.dim1 != other.dim1 or self.dim2 != other.dim2:
            print("Non-matching dimensions for addition. Returning null matrix")
            return Self(0, 0, 0)

        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix *= 0

        @parameter
        fn channel_fn(c: Int):
            @parameter
            fn row_fn(y: Int):
                @parameter
                fn col_fn[simd_width: Int](x: Int):
                    let simd_val = self.load[simd_width](c, y, x)
                    let simd_val2 = other.load[simd_width](c, y, x)
                    let computed_val = simd_val.__add__(simd_val2)
                    new_matrix.store[simd_width](c, y, x, computed_val)

                vectorize_unroll[simd_width, simd_width, col_fn](self.dim2)

            parallelize[row_fn](self.dim1, self.dim1)

        parallelize[channel_fn](self.dim0, self.dim0)

        return new_matrix

    fn __iadd__(self, y: float_base) -> None:
        @parameter
        fn add_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__add__(y_simd)
            self._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, add_fn](self.size().to_int())

    fn __isub__(self, y: float_base) -> None:
        @parameter
        fn sub_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__add__(-y_simd)
            self._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, sub_fn](self.size().to_int())

    fn __truediv__(self, y: float_base)  -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        var new_matrix_size = new_matrix.size().to_int()

        @parameter
        fn div_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__truediv__(
                y_simd
            )
            new_matrix._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, div_fn](new_matrix_size)

        return new_matrix

    fn __itruediv__(self, y: float_base) -> None:
        @parameter
        fn div_fn[simd_width: Int](index: Int) -> None:
            let y_simd = SIMD[dtype, simd_width].splat(y.cast[dtype]())
            let computed_val = self._data.simd_load[simd_width](index).__truediv__(
                y_simd
            )
            self._data.simd_store[simd_width](index, computed_val)

        vectorize[simd_width, div_fn](self.size().to_int())

    fn sum(self) -> SIMD[dtype, 1]:
        var sum_simd = SIMD[dtype, 1].splat(0.0)

        for index in range(self.size().to_int()):
            sum_simd += self._data.simd_load[1](index)

        return sum_simd

    fn mean(self) -> SIMD[dtype, 1]:
        return self.sum().__truediv__(self.size().cast[dtype]())

    # we use an unbiased estimator of the standard deviation
    fn std(self) -> SIMD[dtype, 1]:
        let mean = self.mean()
        let sum = self.sum()
        var sq_sum = SIMD[dtype, 1].splat(0.0)

        for i in range(self.size().to_int()):
            sq_sum += (self._data.simd_load[1](i) - mean) ** 2

        return math.sqrt(sq_sum / self.size().cast[dtype]())

    # Order of padding is (top, bottom), (left, right)
    fn pad(self, padding_height: Tuple, padding_width: Tuple)  -> Self:
        let matrix_height = self.dim1
        let matrix_width = self.dim2
        let padding_height_top = Tuple.get[0, Int](padding_height)
        let padding_height_bottom = Tuple.get[1, Int](padding_height)
        let padding_width_left = Tuple.get[0, Int](padding_width)
        let padding_width_right = Tuple.get[1, Int](padding_width)
        let padded_width = (matrix_width + padding_width_left + padding_width_right)
        let padded_height = (matrix_height + padding_height_top + padding_height_bottom)
        let padded = Self(self.dim0, padded_height, padded_width)
        padded *= 0

        @parameter
        fn channel_fn(c: Int):
            @parameter
            fn row_fn(y: Int):
                @parameter
                fn col_fn[simd_width: Int](x: Int):
                    let c_simd = SIMD[dtype, simd_width].splat(c)
                    let x_simd = SIMD[dtype, simd_width].splat(x + padding_width_left)
                    let y_simd = SIMD[dtype, simd_width].splat(y + padding_height_top)
                    padded[c, y + padding_height_top, x + padding_width_left] = self[
                        c, y, x
                    ]

                vectorize_unroll[1, 1, col_fn](matrix_width)

            parallelize[row_fn](matrix_height, matrix_height)

        parallelize[channel_fn](self.dim0, self.dim0)
        return padded

    # Elementwise multiplication. Usage:
    # let c = a.multiply(b)
    fn multiply(self, matrix: Self) -> Self:
        if self.dim0 != matrix.dim0 or self.dim1 != matrix.dim1 or self.dim2 != matrix.dim2:
            print("Non-matching dimensions for elementwise multiplication. Returning null matrix")
            return Self(0, 0, 0)

        var new_matrix = Self(self.dim0, self.dim1, matrix.dim2)
        new_matrix *= 0

        @parameter
        fn channel_fn(c: Int):
            @parameter
            fn row_fn(y: Int):
                @parameter
                fn col_fn[simd_width: Int](x: Int):
                    let simd_val = self.load[simd_width](c, y, x)
                    let simd_val2 = matrix.load[simd_width](c, y, x)
                    let computed_val = simd_val.__mul__(simd_val2)
                    new_matrix.store[simd_width](c, y, x, computed_val)

                vectorize_unroll[simd_width, simd_width, col_fn](self.dim2)

            parallelize[row_fn](self.dim1, self.dim1)

        parallelize[channel_fn](self.dim0, self.dim0)

        return new_matrix

    fn clamp(self, min_val: float_base, max_val: float_base) -> Self:
        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix *= 0

        @parameter
        fn clamp_fn[simd_width: Int](index: Int):
            let min_simd = SIMD[dtype, simd_width].splat(min_val.cast[dtype]())
            let max_simd = SIMD[dtype, simd_width].splat(max_val.cast[dtype]())
            let val = self._data.simd_load[simd_width](index)
            let computed_val = val.max(min_simd).min(max_simd)
            new_matrix._data.simd_store[simd_width](index, computed_val)

        vectorize_unroll[simd_width, simd_width, clamp_fn](self.size().to_int())

        return new_matrix

    # Usage: let c = b.chunk(2, 2)
    fn chunk(self, chunk_dim: Int, num_chunks: Int) -> Matrix_Array[dtype]:
        if chunk_dim < 0 or chunk_dim  >= 3:
            print("Out of bounds chunk dimension. Returning null array")
            return Matrix_Array[dtype](0, (0,0,0))

        var chunk_axis = self.dim0
        if chunk_dim == 1:
            chunk_axis = self.dim1
        elif chunk_dim == 2:
            chunk_axis = self.dim2

        if num_chunks > chunk_axis:
            print("Number of chunks exceeds the size of the chunk axis. Returning null array")
            return Matrix_Array[dtype](0, (0,0,0))

        # For now, we only support chunking evenly for simplicity
        if chunk_axis % num_chunks != 0:
            print("Number of chunks does not evenly divide the size of the chunk axis. Returning null array")
            return Matrix_Array[dtype](0, (0,0,0))
        
        let chunk_size = chunk_axis // num_chunks
        var out_size = (chunk_size, self.dim1, self.dim2)
        if chunk_dim == 1:
            out_size = (self.dim0, chunk_size, self.dim2)
        elif chunk_dim == 2:
            out_size = (self.dim0, self.dim1, chunk_size)

        var out_array = Matrix_Array[dtype](num_chunks, out_size)
        
        @parameter
        fn chunk_fn(index: Int):
            let chunk_start = index * chunk_size
            let chunk_end = (index + 1) * chunk_size
            let chunk_slice = slice(chunk_start, chunk_end)
            if chunk_dim == 0:
                out_array[index] = self[chunk_slice, slice(0, self.dim1), slice(0, self.dim2)]
            elif chunk_dim == 1:
                out_array[index] = self[slice(0, self.dim0), chunk_slice, slice(0, self.dim2)]
            elif chunk_dim == 2:
                out_array[index] = self[slice(0, self.dim0), slice(0, self.dim1), chunk_slice]

        parallelize[chunk_fn](num_chunks, num_chunks)

        return out_array
        

    # Usage: var d = b.transpose(0, 1) --> flips the coordinates for the 0 and 1 axes
    fn transpose(inout self, dim0: Int = 1, dim1: Int = 2) -> Self:
        if dim0 < 0 or dim0 >= 3 or dim1 < 0 or dim1 >= 3:
            print("Dimensions for transpose exceed matrix dimensions. Returning null matrix")
            return Self(0, 0, 0)

        if dim0 == dim1:
            return self

        # This covers the 0 and 1 case
        var new_matrix =  Self(self.dim1, self.dim0, self.dim2)
        if (dim0 == 0 and dim1 == 2) or (dim0 == 2 and dim1 == 0):
            new_matrix = Self(self.dim2, self.dim1, self.dim0)
        elif (dim0 == 1 and dim1 == 2) or (dim0 == 2 and dim1 == 1):
            new_matrix = Self(self.dim0, self.dim2, self.dim1)
        new_matrix *= 0

        @parameter
        fn transpose_fn[block_width: Int](index: Int):
            let x = index % self.dim2
            let y = (index // self.dim2) % self.dim1
            let z = index // (self.dim1 * self.dim2)
            var new_x = x
            var new_y = y
            var new_z = z
            if (dim0 == 0 and dim1 == 1) or (dim0 == 1 and dim1 == 0):
                new_z = y
                new_y = z
            if (dim0 == 0 and dim1 == 2) or (dim0 == 2 and dim1 == 0):
                new_x = z
                new_z = x
            if (dim0 == 1 and dim1 == 2) or (dim0 == 2 and dim1 == 1):
                new_y = x
                new_x = y

            new_matrix[new_z, new_y, new_x] = self[z, y, x]

        vectorize_unroll[1, 1, transpose_fn](self.size().to_int())

        return new_matrix
    
    # This can be further optimized with tiling (for simplicity, I didn't use it here)
    fn matmul(inout self, matrix: Self) -> Self:
        if self.dim2 != matrix.dim1:
            print("Non-matching dimensions for matrix multiplication. Returning null matrix")
            return Self(0, 0, 0)

        var new_matrix = Self(self.dim0, self.dim1, matrix.dim2)
        new_matrix *= 0
        
        @parameter
        fn calc_channel(c: Int):
            @parameter
            fn calc_row(m: Int):
                for k in range(self.dim2):
                    @parameter
                    fn dot[simd_width : Int](n : Int):
                        new_matrix[c, m, n] += self[c, m, k] * matrix[c, k, n]
                    vectorize_unroll[1, 1, dot](new_matrix.dim2)
            parallelize[calc_row](self.dim1, new_matrix.dim1)
        parallelize[calc_channel](self.dim0, new_matrix.dim0)

        return new_matrix

    fn triu(self, diagonal: Int = 0) -> Self:
        if diagonal != 0  and diagonal != 1:
            print("Invalid diagonal value. Returning null matrix")
            return Self(0, 0, 0)

        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)

        @parameter
        fn triu_channel(channel_idx: Int):
            @parameter
            fn triu_row(row_idx: Int):
                @parameter
                fn triu_col[width: Int](col_idx: Int):
                    if diagonal == 0:
                        if row_idx > col_idx:
                            new_matrix[channel_idx, row_idx, col_idx] = 0.0
                    else:
                        let adjusted_row_idx = new_matrix.dim1 - row_idx - 1

                        if row_idx < col_idx:
                            new_matrix[channel_idx, adjusted_row_idx, col_idx] = 0.0
                vectorize_unroll[1, 1, triu_col](self.dim2)
            parallelize[triu_row](self.dim1, self.dim1)
        parallelize[triu_channel](self.dim0, self.dim0)

        return new_matrix

    fn masked_fill(self, mask: Self, value: float_base) -> Self:
        if self.dim0 != mask.dim0 or self.dim1 != mask.dim1 or self.dim2 != mask.dim2:
            print("Non-matching dimensions for masked fill. Returning null matrix")
            return Self(0, 0, 0)

        var new_matrix = Self(self.dim0, self.dim1, self.dim2)
        new_matrix.__copyinit__(self)
        let simd_value = SIMD[dtype, 1].splat(value.cast[dtype]())

        @parameter
        fn masked_fill_channel(channel_idx: Int):
            @parameter
            fn masked_fill_row(row_idx: Int):
                @parameter
                fn masked_fill_col[width: Int](col_idx: Int):
                    if mask[channel_idx, row_idx, col_idx] != 0:
                        new_matrix[channel_idx, row_idx, col_idx] = simd_value
                vectorize_unroll[1, 1, masked_fill_col](self.dim2)
            parallelize[masked_fill_row](self.dim1, self.dim1)
        parallelize[masked_fill_channel](self.dim0, self.dim0)

        return new_matrix

    fn print(self, prec: Int = 4) -> None:
        let dim0: Int = self.dim0
        let dim1: Int = self.dim1
        let dim2: Int = self.dim2
        var val: SIMD[dtype, 1] = 0.0

        if dim0 == 1 and dim1 == 1 and dim2 == 1:
            print(self[0, 0, 0])
            return

        if dim0 > 0 and dim1 > 0 and dim2 > 0:
            for i in range(dim0):
                for j in range(dim1):
                    if j == 0:
                        print_no_newline("\n[\n")
                    else:
                        print_no_newline("\n")
                    print_no_newline(" [")
                    for k in range(dim2):
                        val = self[i, j, k]
                        let int_str: String
                        if val > 0 or val == 0:
                            int_str = String(trunc(val).cast[DType.int32]())
                        else:
                            int_str = "-" + String(trunc(val).cast[DType.int32]())
                            val = -val
                        let float_str: String
                        float_str = String(mod(val, 1))
                        let s = int_str + "." + float_str[2 : prec + 2]
                        if k == 0:
                            print_no_newline(s)
                        else:
                            print_no_newline("  ", s)
                    print_no_newline("]")
                print_no_newline("\n]\n")
            print()
        print(
            "  Matrix:",
            self.dim0,
            "x",
            self.dim1,
            "x",
            self.dim2,
            ",",
            "DType:",
            dtype.__str__(),
        )
        print()


struct Conv2D:
    var out_channels: Int
    var in_channels: Int
    var kernel_size: Int
    var padding: Tuple[Int, Int]
    var stride: Tuple[Int, Int]
    var bias:Tensor[float_dtype]
    var kernel: Matrix_Array[float_dtype]

    fn __init__(
        inout self,
        in_channels: Int,
        out_channels: Int,
        kernel_size: Int,
        padding: Tuple[Int, Int] = (0, 0),
        stride: Tuple[Int, Int] = (1, 1),
    )  -> None:
        self.out_channels = out_channels
        self.in_channels = in_channels
        self.kernel_size = kernel_size
        self.padding = padding
        self.stride = stride

        #### LEARNABLE PARAMETERS
        self.bias = Tensor[float_dtype](out_channels)
        self.kernel = Matrix_Array[float_dtype](out_channels, (in_channels, kernel_size, kernel_size))
        @parameter
        fn init_kernel_fn(out_channel_idx: Int):
            var curr_matrix = Matrix[float_dtype](self.in_channels, self.kernel_size, self.kernel_size)
            let k = (self.in_channels * self.kernel_size * self.kernel_size)
            let inv_k = math.rsqrt[float_dtype, 1](k)
            curr_matrix.init_weights(-inv_k, inv_k)
            self.kernel[out_channel_idx] = curr_matrix
        parallelize[init_kernel_fn](self.out_channels, self.out_channels)
        ####

    fn forward(
        self,
        matrix: Matrix[float_dtype],
    )  -> Matrix[float_dtype]:

        var conv_matrix = matrix
        let padding_height = Tuple.get[0, Int](self.padding)
        let padding_width = Tuple.get[1, Int](self.padding)
        if Tuple.get[0, Int](self.padding) != 0 or Tuple.get[1, Int](self.padding) != 0:
            conv_matrix = conv_matrix.pad((padding_height, padding_height), (padding_width, padding_width))
        let height = conv_matrix.dim1
        let width = conv_matrix.dim2
        let stride_y = Tuple.get[0, Int](self.stride)
        let stride_x = Tuple.get[1, Int](self.stride)
        let final_height = math.floor(
            (height - self.kernel_size) / stride_y + 1
        ).to_int()

        let final_width = math.floor(
            (width - self.kernel_size) / stride_x + 1
        ).to_int()

        let output =
            Matrix[float_dtype](self.out_channels, final_height, final_width)

        @parameter
        fn channel_fn(out_channel_idx: Int):
            let kernel_channel = self.kernel[out_channel_idx]
            @parameter
            fn convolution_fn[stride_x: Int, stride_y: Int](x: Int, y: Int):
                let x_out = x // stride_x
                let y_out = y // stride_y
                var convolution_sum = SIMD[float_dtype, 1].splat(0.0)
                for in_channel_idx in range(self.in_channels):
                    let convolution_region = conv_matrix[
                        in_channel_idx,
                        y : y + self.kernel_size,
                        x : x + self.kernel_size,
                    ]
                    let kernel_region = kernel_channel[in_channel_idx,:,:]
                    let elementwise_mult = convolution_region.multiply(kernel_channel[in_channel_idx,:,:]).sum()

                    convolution_sum += elementwise_mult

                output[out_channel_idx, y_out, x_out] = convolution_sum + self.bias[out_channel_idx]

            let end_x = width - self.kernel_size + 1
            let end_y = height - self.kernel_size + 1

            # Here, we use these annoying if statements because the tiling function does not support dynamic values. Nonetheless, tiling gives a huge performance boost.
            if stride_x == 1 and stride_y == 1:
                tile_2d[convolution_fn, 1, 1](end_x, end_y)
            elif stride_x == 1 and stride_y == 0:
                tile_2d[convolution_fn, 1, 0](end_x, end_y)
            elif stride_x == 0 and stride_y == 1:
                tile_2d[convolution_fn, 0, 1](end_x, end_y)
            elif stride_x == 0 and stride_y == 0:
                tile_2d[convolution_fn, 0, 0](end_x, end_y)
            elif stride_x == 1 and stride_y == 2:
                tile_2d[convolution_fn, 1, 2](end_x, end_y)
            elif stride_x == 2 and stride_y == 1:
                tile_2d[convolution_fn, 2, 1](end_x, end_y)
            elif stride_x == 2 and stride_y == 2:
                tile_2d[convolution_fn, 2, 2](end_x, end_y)
            elif stride_x == 2 and stride_y == 0:
                tile_2d[convolution_fn, 2, 0](end_x, end_y)
            elif stride_x == 0 and stride_y == 2:
                tile_2d[convolution_fn, 0, 2](end_x, end_y)
            elif stride_x == 0 and stride_y == 0:
                tile_2d[convolution_fn, 0, 0](end_x, end_y)
        
        parallelize[channel_fn](self.out_channels, self.out_channels)
        
        return output

struct GroupNorm:
    var num_groups: Int
    var num_channels: Int
    var channels_per_group: Int
    var epsilon: float_base
    var gamma: float_base
    var beta: float_base

    fn __init__(
        inout self,
        num_groups: Int,
        num_channels: Int,
        epsilon: float_base = 1e-5,
    ) -> None:
        self.num_groups = num_groups
        self.num_channels = num_channels
        self.channels_per_group = math.floor(num_channels / num_groups).to_int()
        self.epsilon = epsilon

        ### LEARNABLE PARAMETERS
        self.gamma = 1.0
        self.beta = 0.0
        ###

    fn forward(self, x: Matrix[float_dtype])  -> Matrix[float_dtype]:
        let output = Matrix[float_dtype](x.dim0, x.dim1, x.dim2)

        if self.num_channels > x.dim0:
            print("Number of channels exceeds the number of channels in the input matrix. Returning null matrix")
            return Matrix[float_dtype](0, 0, 0)
            
        if self.num_channels % self.num_groups != 0:
            print("Number of channels does not evenly divide the number of groups. Returning null matrix")
            return Matrix[float_dtype](0, 0, 0)

        @parameter
        fn channel_fn(i: Int):
            let channels_group = x[
                i * self.channels_per_group : (i + 1) * self.channels_per_group, :,:
            ]

            let mean = channels_group.mean()
            let std = channels_group.std()

            @parameter
            fn channels_per_group_fn(m: Int):
                @parameter
                fn compute_element[simd_width: Int](index: Int):
                    let channels_index = m * x.dim1 * x.dim2 + index
                    let curr_el = channels_group._data.simd_load[simd_width](channels_index)

                    let el_normalized = (curr_el - mean) / (
                        std + self.epsilon
                    ) * self.gamma

                    let out_index = i * self.channels_per_group * x.dim1 * x.dim2 + m * x.dim1 * x.dim2 + index

                    output._data.simd_store[simd_width](out_index, el_normalized)

                vectorize_unroll[simd_width, simd_width, compute_element](x.dim1 * x.dim2)

            parallelize[channels_per_group_fn](self.channels_per_group, self.channels_per_group)

        parallelize[channel_fn](self.num_groups, self.num_groups)

        return output


struct SiLU:
    fn __init__(inout self) -> None:
        pass

    fn forward(self, x: Matrix[float_dtype]) -> Matrix[float_dtype]:
        var matrix = x

        @parameter
        fn vec_sigmoid[simd_width: Int](idx: Int) -> None:
            let x_idx = x._data.simd_load[simd_width](idx)
            matrix._data.simd_store[simd_width](idx, x_idx / (1 + math.exp(-x_idx)))

        vectorize_unroll[simd_width, simd_width, vec_sigmoid](matrix.size().to_int())

        return matrix

struct Linear:
    var in_features: Int
    var out_features: Int
    var num_channels: Int
    var bias: Matrix[float_dtype]
    var weight: Matrix[float_dtype]
    var use_bias: Bool

    fn __init__(
        inout self,
        in_features: Int,
        out_features: Int,
        num_channels: Int = 1,
        use_bias : Bool = True,
    ) -> None:
        self.in_features = in_features
        self.out_features = out_features
        self.num_channels = num_channels
        self.use_bias = use_bias

        ### LEARNABLE PARAMETERS: bias and weight
        self.bias = Matrix[float_dtype](num_channels, 1, out_features)
        let k = math.sqrt(self.in_features)
        let inv_k = math.rsqrt[float_dtype, 1](k)
        self.bias.init_weights(-inv_k, inv_k)
        self.weight = Matrix[float_dtype](num_channels, out_features, in_features)
        self.weight.init_weights(-inv_k, inv_k)
        ###

    fn forward(inout self, inout x: Matrix[float_dtype]) -> Matrix[float_dtype]:
        if x.dim2 != self.in_features:
            print("Invalid input dimensions for Linear layer. Returning null matrix")
            return Matrix[float_dtype](0, 0, 0)
        
        var output = x.matmul(self.weight.transpose(1,2))

        if self.use_bias:
            var bias_matrix = Matrix[float_dtype](output.dim0, output.dim1, output.dim2)

            # Setting bias vectors in the same column to the same value
            @parameter
            fn channel_fn(i: Int):
                @parameter
                fn col_fn(j: Int):
                    bias_matrix.set_items(i, slice(0, bias_matrix.dim1), j, self.bias[i, 0, j])
                
                parallelize[col_fn](bias_matrix.dim1, bias_matrix.dim1)

            parallelize[channel_fn](self.num_channels, self.num_channels)
            output = output + bias_matrix

        return output